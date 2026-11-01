#!/usr/bin/env python3
"""
ping_cube.py — Tiny Terminal TUI Cube for continuous ICMP ping monitoring.

Zero dependencies (Python 3 standard library only). Works on macOS & Linux.
Features:
  - Full-cube 24-bit ANSI background color (Green = Good, Orange = Ok-ish, Red = Bad)
  - Visual bright-red flash/pulse on packet drop (Request timeout)
  - Big block-digit RTT readout (auto-compacts if terminal height < 9 rows)
  - 25-ping rolling sparkline with per-bar color coding (Green / Orange / Red)
  - 60-second rolling Packet Loss %, Average ms, and Max ms footer
  - Dynamic terminal window title update (e.g., "🟢 18ms | 8.8.8.8")
  - Hotkeys: [p] Pause/Resume, [r] Reset stats, [q] Quit

Usage:
  python3 ping_cube.py
  python3 ping_cube.py --host 8.8.8.8 --warn 40 --bad 100
"""

from __future__ import annotations

import argparse
from collections import deque
import os
import platform
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import time
import tty
from typing import Deque, Optional

# 3-row tall block font for crisp big latency readout inside the cube
BIG_DIGITS = {
    "0": ("┏━┓", "┃ ┃", "┗━┛"),
    "1": (" ╻ ", " ┃ ", " ╹ "),
    "2": ("┏━┓", "┏━┛", "┗━╸"),
    "3": ("┏━┓", " ━┫", "┗━┛"),
    "4": ("╻ ╻", "┗━┫", "  ╹"),
    "5": ("┏━╸", "┗━┓", "┗━┛"),
    "6": ("┏━╸", "┣━┓", "┗━┛"),
    "7": ("┏━┓", "  ┃", "  ╹"),
    "8": ("┏━┓", "┣━┫", "┗━┛"),
    "9": ("┏━┓", "┗━┫", "┗━┛"),
    "m": ("   ", "┏┳┓", "╹╹╹"),
    "s": ("   ", "┏━╸", "╺━┛"),
    " ": (" ", " ", " "),
    "-": ("   ", "━━━", "   "),
    "T": ("┏┳┓", " ┃ ", " ╹ "),
    "I": ("╺┳╸", " ┃ ", "╺┻╸"),
    "M": ("┏┳┓", "┃┃┃", "╹ ╹"),
    "E": ("┏━╸", "┣╸ ", "┗━╸"),
    "O": ("┏━┓", "┃ ┃", "┗━┛"),
    "U": ("╻ ╻", "┃ ┃", "┗━┛"),
    "L": ("╻  ", "┃  ", "┗━╸"),
    "S": ("┏━╸", "┗━┓", "╺━┛"),
}

SPARK_BLOCKS = "▁▂▃▄▅▆▇█"
TIME_RE = re.compile(r"time[=<]([0-9.]+)\s*ms", re.IGNORECASE)

# 24-bit ANSI color helpers
ESC = "\033"
RESET = f"{ESC}[0m"
BOLD = f"{ESC}[1m"


def bg_rgb(r: int, g: int, b: int) -> str:
    return f"{ESC}[48;2;{r};{g};{b}m"


def fg_rgb(r: int, g: int, b: int) -> str:
    return f"{ESC}[38;2;{r};{g};{b}m"


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def visible_len(text: str) -> int:
    return len(strip_ansi(text))


def pad_center(text: str, width: int, fill_bg: str, default_fg: str) -> str:
    vlen = visible_len(text)
    if vlen >= width:
        return f"{fill_bg}{default_fg}{text}{RESET}"
    left = (width - vlen) // 2
    right = width - vlen - left
    return f"{fill_bg}{default_fg}{' ' * left}{text}{fill_bg}{default_fg}{' ' * right}{RESET}"


def pad_lr(left_text: str, right_text: str, width: int, fill_bg: str, default_fg: str) -> str:
    vlen = visible_len(left_text) + visible_len(right_text)
    gap = max(1, width - vlen - 2)
    return f"{fill_bg}{default_fg} {left_text}{fill_bg}{default_fg}{' ' * gap}{right_text}{fill_bg}{default_fg} {RESET}"


def render_big_text(label: str) -> tuple[str, str, str]:
    rows = ["", "", ""]
    for idx, ch in enumerate(label):
        glyph = BIG_DIGITS.get(ch, ("?", "?", "?"))
        sep = " " if idx > 0 and ch != " " else ""
        for r in range(3):
            rows[r] += sep + glyph[r]
    return rows[0], rows[1], rows[2]


class PingMonitorTUI:
    def __init__(self, host: str, warn_ms: float, bad_ms: float, jitter_warn_ms: float, interval: float) -> None:
        self.host = host
        self.warn_ms = warn_ms
        self.bad_ms = bad_ms
        self.jitter_warn_ms = jitter_warn_ms
        self.interval = interval

        self.samples: Deque[Optional[float]] = deque(maxlen=60)
        self.current_rtt: Optional[float] = None
        self.has_received_any: bool = False
        self.paused: bool = False
        self.flash_until: float = 0.0
        self.last_sample_ts: float = time.monotonic()
        self.proc: Optional[subprocess.Popen[str]] = None

    def start_ping(self) -> None:
        self.stop_ping()
        system = platform.system().lower()
        if system == "darwin":
            cmd = ["/sbin/ping", "-n", "-i", str(self.interval), self.host]
        else:
            cmd = ["ping", "-n", "-O", "-i", str(self.interval), "-W", "1", self.host]

        self.proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self.last_sample_ts = time.monotonic()

    def stop_ping(self) -> None:
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=0.5)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None

    def record_sample(self, rtt_ms: Optional[float]) -> None:
        self.has_received_any = True
        self.current_rtt = rtt_ms
        self.samples.append(rtt_ms)
        self.last_sample_ts = time.monotonic()
        if rtt_ms is None:
            self.flash_until = time.monotonic() + 0.38

    def parse_line(self, line: str) -> None:
        s = line.strip()
        if not s or s.startswith("PING ") or s.startswith("---") or "packets transmitted" in s:
            return
        m = TIME_RE.search(s)
        if m:
            self.record_sample(float(m.group(1)))
            return
        low = s.lower()
        if (
            "timeout" in low
            or "no answer" in low
            or "unreachable" in low
            or "no route" in low
            or "sendto:" in low
        ):
            self.record_sample(None)

    def sample_health(self, rtt_ms: Optional[float]) -> str:
        if rtt_ms is None:
            return "bad"
        if rtt_ms >= self.bad_ms:
            return "bad"
        if rtt_ms >= self.warn_ms:
            return "ok"
        return "good"

    def jitter_ms(self) -> int:
        recent_valid = [x for x in list(self.samples)[-20:] if x is not None]
        if len(recent_valid) < 2:
            return 0
        diffs = [abs(recent_valid[i] - recent_valid[i - 1]) for i in range(1, len(recent_valid))]
        return int(round(sum(diffs) / len(diffs)))

    def overall_health(self) -> str:
        if self.paused:
            return "paused"
        if not self.has_received_any:
            return "init"
        if self.current_rtt is None or self.current_rtt >= self.bad_ms:
            return "bad"
        recent_10 = list(self.samples)[-10:]
        recent_drops = sum(1 for x in recent_10 if x is None)
        if self.current_rtt >= self.warn_ms or recent_drops > 0 or self.jitter_ms() >= self.jitter_warn_ms:
            return "ok"
        return "good"

    def stats_summary(self) -> tuple[int, Optional[int], Optional[int]]:
        if not self.samples:
            return 0, None, None
        drops = sum(1 for x in self.samples if x is None)
        loss_pct = int(round((drops / len(self.samples)) * 100.0))
        valid = [x for x in self.samples if x is not None]
        if not valid:
            return loss_pct, None, None
        avg_ms = int(round(sum(valid) / len(valid)))
        max_ms = int(round(max(valid)))
        return loss_pct, avg_ms, max_ms

    def sparkline_str(self, width: int, fill_bg: str) -> str:
        count = min(25, max(10, width - 2))
        recent = list(self.samples)[-count:]
        empty_count = count - len(recent)

        dim_fg = fg_rgb(255, 255, 255)
        green_fg = fg_rgb(110, 255, 160)
        orange_fg = fg_rgb(255, 200, 70)
        red_fg = fg_rgb(255, 110, 110)

        parts: list[str] = []
        if empty_count > 0:
            parts.append(f"{fill_bg}{dim_fg}{'·' * empty_count}")

        for val in recent:
            if val is None:
                parts.append(f"{fill_bg}{red_fg}█")
            else:
                clamped = min(max(val, 2.0), 120.0)
                idx = min(len(SPARK_BLOCKS) - 1, int((clamped / 120.0) * len(SPARK_BLOCKS)))
                ch = SPARK_BLOCKS[idx]
                h = self.sample_health(val)
                if h == "good":
                    parts.append(f"{fill_bg}{green_fg}{ch}")
                elif h == "ok":
                    parts.append(f"{fill_bg}{orange_fg}{ch}")
                else:
                    parts.append(f"{fill_bg}{red_fg}{ch}")
        return "".join(parts)

    def render_frame(self) -> str:
        cols, rows = shutil.get_terminal_size(fallback=(28, 10))
        cols = max(20, cols)
        rows = max(5, rows)

        state = self.overall_health()
        is_flashing = time.monotonic() < self.flash_until

        if is_flashing:
            bg = bg_rgb(225, 28, 28)  # Bright neon pulse on packet loss
            badge = "LOSS!"
            emoji = "🔴"
        elif state == "good":
            bg = bg_rgb(14, 108, 56)  # Deep Emerald Green
            badge = "GOOD"
            emoji = "🟢"
        elif state == "ok":
            bg = bg_rgb(176, 82, 10)  # Warm Amber / Orange
            badge = "OK-ISH"
            emoji = "🟠"
        elif state == "bad":
            bg = bg_rgb(158, 22, 22)  # Crimson Red
            badge = "BAD"
            emoji = "🔴"
        elif state == "paused":
            bg = bg_rgb(52, 58, 68)
            badge = "PAUSED"
            emoji = "⏸"
        else:
            bg = bg_rgb(38, 44, 54)
            badge = "INIT"
            emoji = "⚪"

        white = fg_rgb(255, 255, 255)
        soft_white = fg_rgb(228, 238, 232)
        badge_style = f"{bg_rgb(0, 0, 0)}{fg_rgb(255, 255, 255)}{BOLD} {badge} {bg}{white}"

        loss_pct, avg_ms, max_ms = self.stats_summary()
        jit_ms = self.jitter_ms()

        if self.paused:
            hero_short = "PAUSED"
            title_ms = "PAUSED"
        elif not self.has_received_any:
            hero_short = "..."
            title_ms = "..."
        elif self.current_rtt is None:
            hero_short = "LOSS"
            title_ms = "LOSS"
        else:
            ms_int = int(round(self.current_rtt))
            hero_short = f"{ms_int} ms"
            title_ms = f"{ms_int}ms"

        # Update terminal window title bar
        window_title = f"{ESC}]0;{emoji} {title_ms} (±{jit_ms}ms) | {self.host} (L:{loss_pct}%){ '\007' }"

        header_line = pad_lr(
            f"{BOLD}● {self.host}",
            badge_style,
            cols,
            bg,
            white,
        )

        jit_color = fg_rgb(255, 218, 90) if jit_ms >= self.jitter_warn_ms else soft_white
        jitter_line = pad_center(f"±{jit_ms}ms jitter", cols, bg, jit_color)

        spark_line = pad_center(self.sparkline_str(cols, bg), cols, bg, white)

        avg_str = f"{avg_ms}" if avg_ms is not None else "-"
        max_str = f"{max_ms}" if max_ms is not None else "-"
        footer_text = f"L:{loss_pct}%  Avg:{avg_str}  ▲{max_str}"
        if cols < 24:
            footer_text = f"L:{loss_pct}% A:{avg_str} ▲{max_str}"
        footer_line = pad_center(footer_text, cols, bg, soft_white)

        blank_line = f"{bg}{' ' * cols}{RESET}"

        content_lines: list[str] = []
        if rows >= 9 and cols >= 22 and hero_short not in ("PAUSED", "..."):
            r1, r2, r3 = render_big_text(hero_short)
            content_lines = [
                header_line,
                blank_line,
                pad_center(f"{BOLD}{r1}", cols, bg, white),
                pad_center(f"{BOLD}{r2}", cols, bg, white),
                pad_center(f"{BOLD}{r3}", cols, bg, white),
                jitter_line,
                spark_line,
                footer_line,
            ]
        else:
            content_lines = [
                header_line,
                pad_center(f"{BOLD}{hero_short}  ±{jit_ms}ms", cols, bg, white),
                spark_line,
                footer_line,
            ]

        # Vertically center content inside the full-colored terminal cube
        total_pad = max(0, rows - len(content_lines))
        top_pad = total_pad // 2
        bottom_pad = total_pad - top_pad

        full_screen_lines = (
            [blank_line] * top_pad
            + content_lines[:rows]
            + [blank_line] * bottom_pad
        )

        return window_title + f"{ESC}[H" + "\r\n".join(full_screen_lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Tiny Terminal TUI Cube for continuous ping monitoring.")
    parser.add_argument("target", nargs="?", default=None, help="Target host/IP (default: 8.8.8.8)")
    parser.add_argument("--host", default="8.8.8.8", help="Target host/IP (default: 8.8.8.8)")
    parser.add_argument("--warn", type=float, default=40.0, help="Orange (ok-ish) RTT threshold in ms (default: 40)")
    parser.add_argument("--bad", type=float, default=100.0, help="Red (bad) RTT threshold in ms (default: 100)")
    parser.add_argument("--jitter-warn", type=float, default=15.0, help="Orange (ok-ish) jitter threshold in ms (default: 15)")
    parser.add_argument("--interval", type=float, default=1.0, help="Ping interval in seconds (default: 1.0)")
    parser.add_argument("--demo", action="store_true", help="Render a single simulated demo frame and exit")
    args = parser.parse_args()

    host = args.target or args.host
    tui = PingMonitorTUI(host=host, warn_ms=args.warn, bad_ms=args.bad, jitter_warn_ms=args.jitter_warn, interval=args.interval)

    if args.demo:
        demo_rtts = [
            38.6, 18.4, 20.4, 26.4, 17.9, 24.4, 17.0, 64.5, 17.8, 16.5,
            57.8, 43.2, 19.1, 21.0, 18.2, 17.5, None, 22.3, 19.8, 18.4,
            17.9, 20.1, 18.0, 17.6, 18.3,
        ]
        for r in demo_rtts:
            tui.record_sample(r)
        tui.flash_until = 0.0
        sys.stdout.write(tui.render_frame() + "\n")
        return 0

    stdin_fd = sys.stdin.fileno()
    has_tty = os.isatty(stdin_fd)
    old_term = termios.tcgetattr(stdin_fd) if has_tty else None

    def cleanup(*_: object) -> None:
        tui.stop_ping()
        if has_tty and old_term is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_term)
        sys.stdout.write(f"{ESC}[?25h{ESC}[?1049l{RESET}\n")
        sys.stdout.flush()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        if has_tty:
            tty.setcbreak(stdin_fd)
        # Enter alternate screen buffer & hide cursor
        sys.stdout.write(f"{ESC}[?1049h{ESC}[?25l{ESC}[2J")
        sys.stdout.flush()

        tui.start_ping()

        while True:
            sys.stdout.write(tui.render_frame())
            sys.stdout.flush()

            read_fds: list[int] = []
            if has_tty:
                read_fds.append(stdin_fd)
            if tui.proc and tui.proc.stdout and not tui.paused:
                read_fds.append(tui.proc.stdout.fileno())

            rlist, _, _ = select.select(read_fds, [], [], 0.2)

            for fd in rlist:
                if has_tty and fd == stdin_fd:
                    ch = os.read(stdin_fd, 1).decode("utf-8", errors="ignore").lower()
                    if ch in ("q", "\x03"):
                        cleanup()
                    elif ch == "r":
                        tui.samples.clear()
                        tui.current_rtt = None
                        tui.has_received_any = False
                    elif ch == "p":
                        tui.paused = not tui.paused
                        if tui.paused:
                            tui.stop_ping()
                        else:
                            tui.start_ping()
                elif tui.proc and tui.proc.stdout and fd == tui.proc.stdout.fileno():
                    line = tui.proc.stdout.readline()
                    if line:
                        tui.parse_line(line)
                    elif not tui.paused:
                        # Ping process exited (e.g., interface reset); restart
                        time.sleep(0.5)
                        tui.start_ping()

            # Watchdog for silent packet drops if OS ping doesn't emit a timeout line immediately
            if not tui.paused and (time.monotonic() - tui.last_sample_ts) > max(1.8, tui.interval * 1.8):
                tui.record_sample(None)

    finally:
        cleanup()


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env swift
//
// PingCube.swift
// Native macOS Floating Always-on-Top Cube + Menu Bar ICMP Ping Monitor
//
// Compile on macOS:
//   swiftc -O PingCube.swift -o PingCube
// Run:
//   ./PingCube
//   ./PingCube --host 8.8.8.8 --warn 40 --bad 100
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Configuration & CLI Arguments

struct Config {
    var host: String = "8.8.8.8"
    var warnThresholdMs: Double = 40.0
    var badThresholdMs: Double = 100.0
    var jitterWarnThresholdMs: Double = 15.0
    var intervalSec: Double = 1.0
    var sparklineCount: Int = 25
    var rollingWindowCount: Int = 60

    static func fromCommandLine() -> Config {
        var cfg = Config()
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--host", "-h":
                if i + 1 < args.count { cfg.host = args[i + 1]; i += 1 }
            case "--warn", "-w":
                if i + 1 < args.count, let v = Double(args[i + 1]) { cfg.warnThresholdMs = v; i += 1 }
            case "--bad", "-b":
                if i + 1 < args.count, let v = Double(args[i + 1]) { cfg.badThresholdMs = v; i += 1 }
            case "--jitter-warn", "-j":
                if i + 1 < args.count, let v = Double(args[i + 1]) { cfg.jitterWarnThresholdMs = v; i += 1 }
            default:
                if !args[i].hasPrefix("-") {
                    cfg.host = args[i]
                }
            }
            i += 1
        }
        return cfg
    }
}

// MARK: - Data Models

enum NetworkHealth: Equatable {
    case starting
    case good      // Green: < warnThresholdMs and no recent drops
    case okIsh     // Orange: warnThresholdMs...badThresholdMs or recent drop recovery
    case bad       // Red: > badThresholdMs or packet loss / timeout

    var label: String {
        switch self {
        case .starting: return "INIT"
        case .good:     return "GOOD"
        case .okIsh:    return "OK-ISH"
        case .bad:      return "BAD"
        }
    }

    var menuEmoji: String {
        switch self {
        case .starting: return "⚪"
        case .good:     return "🟢"
        case .okIsh:    return "🟠"
        case .bad:      return "🔴"
        }
    }
}

struct PingSample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let rttMs: Double? // nil means timeout / packet loss

    func health(warnMs: Double, badMs: Double) -> NetworkHealth {
        guard let ms = rttMs else { return .bad }
        if ms >= badMs { return .bad }
        if ms >= warnMs { return .okIsh }
        return .good
    }
}

// MARK: - Ping Monitor Engine

final class PingMonitor: ObservableObject {
    @Published private(set) var samples: [PingSample] = []
    @Published private(set) var currentSample: PingSample?
    @Published private(set) var overallHealth: NetworkHealth = .starting
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isFlashing: Bool = false

    let config: Config
    private var process: Process?
    private var pipe: Pipe?
    private var watchdogTimer: Timer?
    private var lastSampleTime: Date = Date()
    private var lineBuffer: String = ""

    var onUpdate: (() -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        guard process == nil else { return }
        isPaused = false
        spawnPingProcess()
        startWatchdog()
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        pipe = nil
    }

    func togglePause() {
        if isPaused {
            start()
        } else {
            isPaused = true
            stop()
            onUpdate?()
        }
    }

    func resetStats() {
        samples.removeAll()
        currentSample = nil
        overallHealth = .starting
        onUpdate?()
    }

    private func spawnPingProcess() {
        let proc = Process()
        let outputPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = ["-n", "-i", String(format: "%.1f", config.intervalSec), config.host]
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consumeOutput(chunk)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.isPaused else { return }
                self.process = nil
                // Restart automatically after 1s if terminated unexpectedly (e.g. Wi-Fi switch)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if !self.isPaused && self.process == nil {
                        self.spawnPingProcess()
                    }
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.pipe = outputPipe
            self.lastSampleTime = Date()
        } catch {
            recordSample(rttMs: nil)
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused else { return }
            let elapsed = Date().timeIntervalSince(self.lastSampleTime)
            if elapsed > max(1.8, self.config.intervalSec * 1.8) {
                self.lastSampleTime = Date()
                self.recordSample(rttMs: nil)
            }
        }
    }

    private func consumeOutput(_ chunk: String) {
        lineBuffer.append(chunk)
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(..<range.upperBound)
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        if line.isEmpty || line.hasPrefix("PING ") || line.hasPrefix("---") || line.contains("packets transmitted") {
            return
        }

        // Match `time=18.381 ms` or `time=18 ms`
        if let timeRange = line.range(of: #"time=([0-9.]+)\s*ms"#, options: .regularExpression) {
            let matchStr = String(line[timeRange])
            let numStr = matchStr
                .replacingOccurrences(of: "time=", with: "")
                .replacingOccurrences(of: "ms", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let rtt = Double(numStr) {
                lastSampleTime = Date()
                recordSample(rttMs: rtt)
                return
            }
        }

        // Match timeouts / unreachable errors
        let lower = line.lowercased()
        if lower.contains("timeout") || lower.contains("unreachable") || lower.contains("no route") || lower.contains("sendto:") || lower.contains("100.0% packet loss") {
            lastSampleTime = Date()
            recordSample(rttMs: nil)
        }
    }

    private func recordSample(rttMs: Double?) {
        let sample = PingSample(timestamp: Date(), rttMs: rttMs)
        currentSample = sample
        samples.append(sample)
        if samples.count > config.rollingWindowCount {
            samples.removeFirst(samples.count - config.rollingWindowCount)
        }

        if rttMs == nil {
            isFlashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.isFlashing = false
            }
        }

        overallHealth = computeOverallHealth(latest: sample)
        onUpdate?()
    }

    private func computeOverallHealth(latest: PingSample) -> NetworkHealth {
        guard let ms = latest.rttMs else {
            return .bad
        }
        if ms >= config.badThresholdMs {
            return .bad
        }
        // Check last 10 pings for any recent drop or high jitter so we show Orange while unstable
        let recent = samples.suffix(10)
        let recentDrops = recent.filter { $0.rttMs == nil }.count
        let currentJitter = Double(jitterMs ?? 0)
        if ms >= config.warnThresholdMs || recentDrops > 0 || currentJitter >= config.jitterWarnThresholdMs {
            return .okIsh
        }
        return .good
    }

    // MARK: - Rolling Metrics (Last 60s)

    var sparklineSamples: [PingSample] {
        Array(samples.suffix(config.sparklineCount))
    }

    var lossPercentage: Int {
        guard !samples.isEmpty else { return 0 }
        let drops = samples.filter { $0.rttMs == nil }.count
        return Int(round((Double(drops) / Double(samples.count)) * 100.0))
    }

    var averageRttMs: Int? {
        let valid = samples.compactMap { $0.rttMs }
        guard !valid.isEmpty else { return nil }
        let sum = valid.reduce(0.0, +)
        return Int(round(sum / Double(valid.count)))
    }

    var maxRttMs: Int? {
        let valid = samples.compactMap { $0.rttMs }
        guard let maxVal = valid.max() else { return nil }
        return Int(round(maxVal))
    }

    /// Mean consecutive RTT variation (|RTT_i - RTT_{i-1}|) over the last 20 valid pings
    var jitterMs: Int? {
        let recentValid = samples.suffix(20).compactMap { $0.rttMs }
        guard recentValid.count >= 2 else { return nil }
        var diffSum = 0.0
        for i in 1..<recentValid.count {
            diffSum += abs(recentValid[i] - recentValid[i - 1])
        }
        return Int(round(diffSum / Double(recentValid.count - 1)))
    }

    var menuBarTitle: String {
        if isPaused {
            return "⏸ PAUSED"
        }
        guard let latest = currentSample else {
            return "⚪ …"
        }
        if let ms = latest.rttMs {
            return "\(overallHealth.menuEmoji) \(Int(round(ms)))ms"
        } else {
            return "🔴 LOSS"
        }
    }
}

// MARK: - SwiftUI Cube View

struct PingCubeView: View {
    @ObservedObject var monitor: PingMonitor

    private var flashOpacity: Double {
        monitor.isFlashing ? 0.65 : 0.0
    }

    private var gradientColors: [Color] {
        if monitor.isPaused {
            return [
                Color(red: 0.22, green: 0.24, blue: 0.28),
                Color(red: 0.14, green: 0.15, blue: 0.18)
            ]
        }
        switch monitor.overallHealth {
        case .starting:
            return [
                Color(red: 0.18, green: 0.20, blue: 0.25),
                Color(red: 0.11, green: 0.13, blue: 0.16)
            ]
        case .good:
            return [
                Color(red: 0.06, green: 0.44, blue: 0.24),
                Color(red: 0.04, green: 0.28, blue: 0.15)
            ]
        case .okIsh:
            return [
                Color(red: 0.68, green: 0.33, blue: 0.04),
                Color(red: 0.44, green: 0.19, blue: 0.02)
            ]
        case .bad:
            return [
                Color(red: 0.68, green: 0.10, blue: 0.10),
                Color(red: 0.42, green: 0.05, blue: 0.05)
            ]
        }
    }

    private var accentDotColor: Color {
        if monitor.isPaused { return Color.gray }
        switch monitor.overallHealth {
        case .starting: return Color.gray
        case .good:     return Color(red: 0.29, green: 0.87, blue: 0.50)
        case .okIsh:    return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .bad:      return Color(red: 0.97, green: 0.44, blue: 0.44)
        }
    }

    var body: some View {
        ZStack {
            // Base colored cube card
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Timeout red pulse overlay
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 1.0, green: 0.15, blue: 0.15).opacity(flashOpacity))

            // Subtle inner border
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22 + flashOpacity * 0.6), lineWidth: 1.2)

            VStack(spacing: 0) {
                // 1. Header: Target IP + Status Badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(accentDotColor)
                        .frame(width: 6, height: 6)
                    Text(monitor.config.host)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(monitor.isPaused ? "PAUSED" : monitor.overallHealth.label)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.black.opacity(0.28))
                        .clipShape(Capsule())
                }
                .padding(.top, 10)
                .padding(.horizontal, 11)

                Spacer(minLength: 2)

                // 2. Hero Center RTT + Jitter Readout
                if monitor.isPaused {
                    Text("PAUSED")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                } else if let sample = monitor.currentSample {
                    if let ms = sample.rttMs {
                        VStack(spacing: -2) {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(Int(round(ms)))")
                                    .font(.system(size: 31, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("ms")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.80))
                            }
                            Text("±\(monitor.jitterMs ?? 0)ms jitter")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(
                                    Double(monitor.jitterMs ?? 0) >= monitor.config.jitterWarnThresholdMs
                                        ? Color(red: 1.0, green: 0.85, blue: 0.35)
                                        : Color.white.opacity(0.78)
                                )
                        }
                    } else {
                        VStack(spacing: 1) {
                            Text("TIMEOUT")
                                .font(.system(size: 19, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            Text("±\(monitor.jitterMs ?? 0)ms jitter")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.78))
                        }
                    }
                } else {
                    Text("…")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer(minLength: 2)

                // 3. Rolling 25-Ping Sparkline
                SparklineBarView(
                    samples: monitor.sparklineSamples,
                    maxCount: monitor.config.sparklineCount,
                    warnMs: monitor.config.warnThresholdMs,
                    badMs: monitor.config.badThresholdMs
                )
                .frame(height: 24)
                .padding(.horizontal, 11)
                .padding(.bottom, 5)

                // 4. Rolling 60s Footer (Loss %, Avg, Max)
                HStack(spacing: 0) {
                    Text("L:\(monitor.lossPercentage)%")
                        .foregroundStyle(monitor.lossPercentage > 0 ? Color(red: 1.0, green: 0.80, blue: 0.80) : Color.white.opacity(0.82))
                    Spacer(minLength: 2)
                    Text("Avg:\(monitor.averageRttMs.map { "\($0)" } ?? "-")")
                        .foregroundStyle(Color.white.opacity(0.82))
                    Spacer(minLength: 2)
                    Text("▲\(monitor.maxRttMs.map { "\($0)" } ?? "-")")
                        .foregroundStyle(Color.white.opacity(0.82))
                }
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 11)
                .padding(.bottom, 9)
            }
        }
        .frame(width: 138, height: 138)
        .animation(.easeOut(duration: 0.55), value: monitor.isFlashing)
    }
}

struct SparklineBarView: View {
    let samples: [PingSample]
    let maxCount: Int
    let warnMs: Double
    let badMs: Double

    private func barColor(for sample: PingSample) -> Color {
        switch sample.health(warnMs: warnMs, badMs: badMs) {
        case .good:
            return Color(red: 0.35, green: 0.95, blue: 0.58)
        case .okIsh:
            return Color(red: 1.00, green: 0.72, blue: 0.22)
        case .bad, .starting:
            return Color(red: 1.00, green: 0.35, blue: 0.35)
        }
    }

    private func normalizedHeight(for sample: PingSample, maxHeight: CGFloat) -> CGFloat {
        guard let ms = sample.rttMs else {
            return maxHeight // Full height red bar on packet drop
        }
        let clamped = min(max(ms, 4.0), 120.0)
        let ratio = CGFloat(clamped / 120.0)
        return max(3.0, ratio * maxHeight)
    }

    var body: some View {
        GeometryReader { geo in
            let emptySlots = max(0, maxCount - samples.count)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<maxCount, id: \.self) { index in
                    let isPlaceholder = index < emptySlots
                    let sample: PingSample? = isPlaceholder ? nil : samples[index - emptySlots]
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(sample.map { barColor(for: $0) } ?? Color.white.opacity(0.14))
                        .frame(height: sample.map { normalizedHeight(for: $0, maxHeight: geo.size.height) } ?? 3.0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Custom Floating Panel

final class FloatingCubePanel: NSPanel {
    var contextMenuProvider: (() -> NSMenu)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?(), let contentView = self.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

// MARK: - Application Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingCubePanel!
    private var monitor: PingMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, no Cmd+Tab clutter
        NSApp.setActivationPolicy(.accessory)

        let config = Config.fromCommandLine()
        monitor = PingMonitor(config: config)

        setupFloatingCubePanel()
        setupMenuBarItem()

        monitor.onUpdate = { [weak self] in
            self?.updateStatusItemTitle()
        }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    private func setupFloatingCubePanel() {
        let size: CGFloat = 138
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = NSPoint(
            x: screenRect.maxX - size - 24,
            y: screenRect.minY + 24
        )

        panel = FloatingCubePanel(
            contentRect: NSRect(origin: defaultOrigin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("PingCubeFloatingWindowFrame")

        panel.contextMenuProvider = { [weak self] in
            self?.buildContextMenu() ?? NSMenu()
        }

        let hostingView = NSHostingView(rootView: PingCubeView(monitor: monitor))
        hostingView.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = hostingView
        panel.orderFrontRegardless()
    }

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = monitor.menuBarTitle
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Left-click: Show/Hide PingCube • Right-click: Options"
        }
    }

    private func updateStatusItemTitle() {
        statusItem?.button?.title = monitor.menuBarTitle
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleCubeVisibility()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            let menu = buildContextMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleCubeVisibility()
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let headerItem = NSMenuItem(
            title: "PingCube — \(monitor.config.host) (Loss: \(monitor.lossPercentage)%, Jitter: ±\(monitor.jitterMs ?? 0)ms)",
            action: nil,
            keyEquivalent: ""
        )
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let toggleCubeTitle = panel.isVisible ? "Hide Floating Cube" : "Show Floating Cube"
        let toggleItem = NSMenuItem(title: toggleCubeTitle, action: #selector(toggleCubeVisibility), keyEquivalent: "c")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let pauseTitle = monitor.isPaused ? "Resume Pings" : "Pause Pings"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let resetItem = NSMenuItem(title: "Reset 60s Stats", action: #selector(resetStats), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit PingCube", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleCubeVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func togglePause() {
        monitor.togglePause()
    }

    @objc private func resetStats() {
        monitor.resetStats()
    }

    @objc private func quitApp() {
        monitor.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let stats = StatsModel()
    private var eventMonitor: Any?
    private var prefsObserver: NSObjectProtocol?
    private let hover = HoverPanel()
    private lazy var widget = DesktopWidget(stats: stats)
    /// Grace period after the cursor leaves the menu bar item before the
    /// floating info panel is dismissed. Long enough to read multi-line text.
    private static let hoverGrace: TimeInterval = 4.0

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.labelColor,
    ]
    private static let thermoPrefix: NSAttributedString = {
        let a = NSTextAttachment()
        a.image = NSImage(systemSymbolName: "thermometer.medium",
                          accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        return NSAttributedString(attachment: a)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        stats.onTick = { [weak self] in self?.updateMenuBarTitle() }
        stats.start()
        // Dump sensor names once at startup (visible in Console.app, filter: hmon-sensor)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            Sensors.dumpNamesOnce()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            // Replace the short-lived system tooltip with a custom panel that
            // we control the lifetime of (see mouseEntered / mouseExited).
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            button.addTrackingArea(area)
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 380)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                stats: stats,
                onQuit: { [weak self] in NSApp.terminate(self) },
                onHeightChange: { [weak self] height in
                    self?.syncPopoverHeight(height)
                }
            )
        )

        // Rebuild the menu bar title and resync the desktop widget whenever
        // any visibility toggle flips.
        prefsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateMenuBarTitle()
            self?.applyWidgetVisibility()
        }

        updateMenuBarTitle()
        applyWidgetVisibility()
    }

    private func applyWidgetVisibility() {
        widget.setVisible(UserDefaults.standard.bool(forKey: Prefs.desktopWidget))
    }

    /// Public toggle so the widget's own header / close affordance can flip
    /// it off. Writes through UserDefaults so the popover toggle stays in sync.
    func toggleDesktopWidget() {
        let key = Prefs.desktopWidget
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem.button else { return }

        let snap = stats.snapshot
        var parts: [String] = []
        var toolTipLines: [String] = []

        if Prefs.enabled(Prefs.menuTemp) {
            let cpuStr = snap.cpuTemp.map { String(format: "%.1f°", $0) } ?? "--°"
            let gpuStr = snap.gpuTemp.map { String(format: "%.1f°", $0) } ?? "--°"
            parts.append("\(cpuStr) \(gpuStr)")
            toolTipLines.append("CPU: \(cpuStr)  GPU: \(gpuStr)")
        }
        if Prefs.enabled(Prefs.menuCPU) {
            parts.append(String(format: "%.0f%%", snap.cpuUsePct))
            toolTipLines.append(String(format: "CPU: %.0f%%", snap.cpuUsePct))
        }
        if Prefs.enabled(Prefs.menuMem) {
            parts.append(String(format: "%.1fG", snap.memUsedGB))
            toolTipLines.append(String(
                format: "RAM: %.1f / %.1f GB", snap.memUsedGB, snap.memTotalGB))
        }
        if Prefs.enabled(Prefs.menuDisk) {
            parts.append(String(format: "%.0fG", snap.diskFreeGB))
            toolTipLines.append(String(
                format: "Disk: %.1f used / %.1f free GB",
                snap.diskUsedGB, snap.diskFreeGB))
        }
        if Prefs.enabled(Prefs.menuBattery), let battery = snap.battery {
            let health = battery.displayHealthPct.map { String(format: "%.0f%%", $0) } ?? "--%"
            parts.append("BAT \(health)")
            toolTipLines.append(batteryToolTip(battery))
        }
        if Prefs.enabled(Prefs.menuNet) {
            let inStr  = compactRate(snap.netInKBs)
            let outStr = compactRate(snap.netOutKBs)
            parts.append("↓\(inStr) ↑\(outStr)")
            toolTipLines.append(String(
                format: "Net: ↓%.1f KB/s  ↑%.1f KB/s", snap.netInKBs, snap.netOutKBs))
        }

        let title = parts.isEmpty ? " hmon" : " " + parts.joined(separator: "  ")

        let attributed = NSMutableAttributedString()
        attributed.append(Self.thermoPrefix)
        attributed.append(NSAttributedString(string: title, attributes: Self.titleAttrs))

        button.attributedTitle = attributed
        button.imagePosition = .imageLeft
        // Suppress the default short-lived tooltip — HoverPanel replaces it.
        button.toolTip = nil

        if hover.isVisible {
            hover.setText(hoverPanelText(snap: snap))
        }
    }

    /// One-line health summary. The capacities divide to the raw ratio, not to
    /// the smoothed figure macOS publishes, so each number is attributed.
    private func batteryToolTip(_ battery: BatteryInfo) -> String {
        let health = battery.displayHealthPct.map { String(format: "%.0f%%", $0) } ?? "--"
        var line = "Battery health: \(health)"
        if battery.appleMaxCapacityPct != nil { line += " (macOS)" }
        if let raw = battery.healthPct, let full = battery.fullChargeCapacity,
           let design = battery.designCapacity {
            line += String(format: "  ·  raw %d/%d = %.1f%%", full, design, raw)
        }
        if let cycles = battery.cycleCount { line += "  ·  \(cycles) cycles" }
        return line
    }

    /// Multi-line text shown in the floating panel. Includes every metric we
    /// can compute regardless of menu-bar visibility — the floating panel is
    /// the place to see everything at a glance.
    private func hoverPanelText(snap: StatsSnapshot) -> String {
        var lines: [String] = []
        if snap.cpuPerCorePct.isEmpty == false || snap.cpuUsePct > 0 {
            lines.append(String(format: "CPU      %5.0f%%  (%d cores)",
                                snap.cpuUsePct, snap.cpuPerCorePct.count))
        }
        let cpuT = snap.cpuTemp.map { String(format: "%.1f°", $0) } ?? "--"
        let gpuT = snap.gpuTemp.map { String(format: "%.1f°", $0) } ?? "--"
        lines.append("Temp     CPU \(cpuT)  GPU \(gpuT)")
        if snap.memTotalGB > 0 {
            lines.append(String(format: "Memory  %5.1f / %.1f GB",
                                snap.memUsedGB, snap.memTotalGB))
        }
        if snap.diskTotalGB > 0 {
            lines.append(String(format: "Disk    %5.0f GB free of %.0f",
                                snap.diskFreeGB, snap.diskTotalGB))
        }
        lines.append(String(format: "Network ↓%6.1f KB/s  ↑%6.1f KB/s",
                            snap.netInKBs, snap.netOutKBs))
        if let battery = snap.battery {
            let health = battery.displayHealthPct.map { String(format: "%.0f%%", $0) } ?? "--"
            let source = battery.appleMaxCapacityPct != nil ? " (macOS)" : ""
            lines.append("Battery  \(health) health\(source) · \(battery.condition)")
            // Shown as its own labelled ratio: these capacities divide to the
            // raw figure, which macOS smooths before publishing.
            if let raw = battery.healthPct, let full = battery.fullChargeCapacity,
               let design = battery.designCapacity {
                lines.append(String(format: "         raw %d / %d mAh = %.1f%%",
                                    full, design, raw))
            }
            if let cycles = battery.cycleCount {
                let rated = battery.designCycleCount.map { " of \($0)" } ?? ""
                lines.append("         \(cycles)\(rated) cycles")
            }
        }
        return lines.joined(separator: "\n")
    }

    @objc func mouseEntered(with event: NSEvent) {
        guard let button = statusItem?.button else { return }
        hover.setText(hoverPanelText(snap: stats.snapshot))
        hover.show(near: button)
    }

    @objc func mouseExited(with event: NSEvent) {
        hover.scheduleHide(after: Self.hoverGrace)
    }

    private func compactRate(_ kbs: Double) -> String {
        if kbs >= 1024 { return String(format: "%.1fM", kbs / 1024) }
        return String(format: "%.1fK", kbs)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            stopEventMonitor()
            stats.setPopoverActive(false)
        } else {
            // The popover takes over — dismiss the hover so they don't overlap.
            hover.hide()
            stats.setPopoverActive(true)
            // NSPopover positions its window from `contentSize` at show time and
            // never re-anchors when the hosted SwiftUI view later resizes itself.
            // Measure first so the very first placement uses the real height.
            sizePopoverToContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            startEventMonitor()
        }
    }

    /// Forces a layout pass on the hosted SwiftUI view and adopts its fitting
    /// height, so `popover.show` anchors against the size it will actually be.
    private func sizePopoverToContent() {
        guard let host = popover.contentViewController?.view else { return }
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize.height
        guard fitting > 1 else { return }
        syncPopoverHeight(fitting)
    }

    /// Keeps `NSPopover.contentSize` in step with the SwiftUI content. Clamped
    /// to the gap below the menu bar so a tall popover can never be placed
    /// partly off-screen, and guarded against re-entrant layout feedback.
    private func syncPopoverHeight(_ height: CGFloat) {
        let available = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight = max(240, available - PopoverView.popoverChrome - 12)
        let clamped = min(height, maxHeight)
        guard abs(popover.contentSize.height - clamped) > 0.5 else { return }
        popover.contentSize = NSSize(width: popover.contentSize.width, height: clamped)
    }

    private func startEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.popover.performClose(nil)
            self?.stopEventMonitor()
            self?.stats.setPopoverActive(false)
        }
    }

    private func stopEventMonitor() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}

/// Lightweight floating info panel that replaces the standard status-item
/// tooltip. Shown on mouseEntered, kept up for a grace period after
/// mouseExited so the user has time to actually read the lines.
final class HoverPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideTimer: Timer?
    private(set) var isVisible = false

    init() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        lbl.maximumNumberOfLines = 0
        lbl.lineBreakMode = .byClipping
        lbl.textColor = .labelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(effect)
        container.addSubview(lbl)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            lbl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = container
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Pass clicks through so the menu bar item still gets them.
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        self.panel = p
        self.label = lbl
    }

    func setText(_ s: String) {
        label.stringValue = s
        if isVisible { relayout() }
    }

    private func relayout() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func show(near button: NSStatusBarButton) {
        cancelHide()
        relayout()
        if let bw = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            let screen = bw.convertToScreen(rectInWindow)
            let size = panel.frame.size
            var origin = NSPoint(x: screen.midX - size.width / 2,
                                  y: screen.minY - size.height - 4)
            // Stay on-screen if the menu bar item is near the right edge.
            if let s = NSScreen.main {
                let maxX = s.visibleFrame.maxX - size.width - 4
                let minX = s.visibleFrame.minX + 4
                origin.x = min(max(origin.x, minX), maxX)
            }
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        isVisible = true
    }

    func scheduleHide(after seconds: TimeInterval) {
        cancelHide()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    func hide() {
        cancelHide()
        panel.orderOut(nil)
        isVisible = false
    }
}

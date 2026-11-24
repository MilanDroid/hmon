import SwiftUI

struct PopoverView: View {
    @ObservedObject var stats: StatsModel
    var onQuit: () -> Void
    /// Label of the footer button that runs `onQuit`. The desktop widget passes
    /// "Close" because its `onQuit` hides only the widget, and "Quit" there
    /// would promise the whole app goes away.
    var quitButtonTitle: String = "Quit"
    /// Called whenever the measured content height settles. The popover host
    /// uses this to keep `NSPopover.contentSize` in sync — without it the
    /// popover anchors against a stale size and drifts off its status item.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    @AppStorage(Prefs.menuTemp) private var menuTemp: Bool = true
    @AppStorage(Prefs.menuMem)  private var menuMem:  Bool = true
    @AppStorage(Prefs.menuNet)  private var menuNet:  Bool = true
    @AppStorage(Prefs.menuCPU)  private var menuCPU:  Bool = true
    @AppStorage(Prefs.menuDisk) private var menuDisk: Bool = true
    @AppStorage(Prefs.menuBattery) private var menuBattery: Bool = true
    @AppStorage(Prefs.desktopWidget) private var desktopWidget: Bool = false

    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var sensorsExpanded: Bool = false
    @State private var coresExpanded: Bool = false
    @State private var batteryExpanded: Bool = false
    /// Seeded to the default popover height rather than 0 so the very first
    /// layout pass isn't degenerate (a 0-height frame makes NSPopover place a
    /// collapsed window it never recovers from).
    @State private var contentHeight: CGFloat = 380

    private var snap: StatsSnapshot { stats.live }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().opacity(0.4)
                tempSection
                cpuSection
                memSection
                diskSection
                netSection
                batterySection
                sensorList
                Divider().opacity(0.4)
//                 widgetToggle
                loginToggle
                footer
            }
            .padding(16)
            .frame(width: 300)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self,
                                           value: proxy.size.height)
                }
            )
        }
        .frame(width: 300, height: min(contentHeight, maxPopoverHeight))
        .onPreferenceChange(ContentHeightKey.self) { measured in
            guard measured > 1 else { return }
            contentHeight = measured
            onHeightChange?(min(measured, maxPopoverHeight))
        }
    }

    /// Largest content height that still lets the popover sit fully between the
    /// menu bar and the bottom of the visible area. `visibleFrame.height` is
    /// exactly that gap; subtract NSPopover's own chrome (13-pt inset on each
    /// side, arrow included) plus a small breathing margin. The outer
    /// ScrollView kicks in when content exceeds this.
    private var maxPopoverHeight: CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return 600 }
        return max(240, visible - Self.popoverChrome - 12)
    }

    /// Total window padding NSPopover adds around its content view.
    static let popoverChrome: CGFloat = 26

    // MARK: Sensors list

    private var sensorList: some View {
        DisclosureGroup(isExpanded: $sensorsExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(snap.allSensors.enumerated()), id: \.offset) { _, reading in
                        sensorRow(reading)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 180)
        } label: {
            Text("All sensors (\(snap.allSensors.count))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func sensorRow(_ reading: Sensors.Reading) -> some View {
        let kind = Sensors.visualKind(of: reading.name)
        return HStack(spacing: 4) {
            Group {
                switch kind {
                case .cpu:   badge("C", color: .orange)
                case .gpu:   badge("G", color: .purple)
                case .other: Color.clear.frame(width: 12, height: 12)
                }
            }
            Text(reading.name)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(String(format: "%.1f°", reading.celsius))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func badge(_ letter: String, color: Color) -> some View {
        Text(letter)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(Circle().fill(color))
    }

    // MARK: Login + footer

    private var widgetToggle: some View {
        Toggle(isOn: $desktopWidget) {
            Text("Show on desktop")
                .font(.system(size: 11, weight: .medium))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private var loginToggle: some View {
        Toggle(isOn: Binding(
            get: { launchAtLogin },
            set: { newValue in
                if LaunchAtLogin.setEnabled(newValue) {
                    launchAtLogin = newValue
                } else {
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }
        )) {
            Text("Launch at login")
                .font(.system(size: 11, weight: .medium))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.tint)
                .font(.system(size: 14, weight: .semibold))
            Text("hmon")
                .font(.system(size: 13, weight: .semibold))
            Link(destination: URL(string: "https://milandroid.dev/")!) {
                Text("by MilanDroid")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .help("Created by MilanDroid — milandroid.dev")
            Spacer()
            Text("live")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
    }

    // MARK: Sections

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("CPU", systemImage: "cpu", menuToggle: $menuCPU)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", snap.cpuUsePct))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !snap.cpuPerCorePct.isEmpty {
                    Text("\(snap.cpuPerCorePct.count) cores")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(max(snap.cpuUsePct / 100, 0), 1))
                .tint(.blue)
            Sparkline(series: [
                .init(values: snap.history.cpuUse, color: .blue),
            ], yMax: 100)

            DisclosureGroup(isExpanded: $coresExpanded) {
                coreGrid
                    .padding(.top, 4)
                if snap.history.cpuPerCore.count > 1 {
                    Sparkline(series: perCoreSparkSeries, yMax: 100, height: 28)
                        .padding(.top, 4)
                }
            } label: {
                Text("Per-core")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Two-column grid of per-core busy% bars. Compact: 9-pt labels, 4-pt bars.
    private var coreGrid: some View {
        let cores = snap.cpuPerCorePct
        let columns = [GridItem(.flexible(), spacing: 10),
                       GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(cores.enumerated()), id: \.offset) { idx, pct in
                HStack(spacing: 6) {
                    Text(String(format: "%2d", idx))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .trailing)
                    ProgressView(value: min(max(pct / 100, 0), 1))
                        .tint(coreTint(idx, total: cores.count))
                    Text(String(format: "%3.0f%%", pct))
                        .font(.system(size: 9, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }

    private var perCoreSparkSeries: [Sparkline.Series] {
        let cores = snap.history.cpuPerCore
        return cores.enumerated().map { idx, values in
            .init(values: values,
                  color: coreTint(idx, total: cores.count).opacity(0.65))
        }
    }

    /// E-cores (typically lower indices on Apple Silicon clusters) get a cooler
    /// hue; P-cores warmer. Cheap visual cue without needing IORegistry probes.
    private func coreTint(_ idx: Int, total: Int) -> Color {
        guard total > 1 else { return .blue }
        let t = Double(idx) / Double(total - 1)
        return Color(hue: 0.58 - t * 0.15, saturation: 0.65, brightness: 0.95)
    }

    private var tempSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Temperature", systemImage: "thermometer", menuToggle: $menuTemp)
            HStack(spacing: 8) {
                tempTile(label: "CPU", value: snap.cpuTemp, color: .orange)
                tempTile(label: "GPU", value: snap.gpuTemp, color: .purple)
                tempTile(label: "BAT", value: snap.batteryTemp, color: .green)
            }
            Sparkline(series: [
                .init(values: snap.history.cpuTemp, color: .orange),
                .init(values: snap.history.gpuTemp, color: .purple),
                .init(values: snap.history.battTemp, color: .green),
            ], yMax: 100)
        }
    }

    // MARK: Battery

    /// The inputs macOS derives battery health from. Hidden entirely on
    /// machines without a battery.
    @ViewBuilder
    private var batterySection: some View {
        if let battery = snap.battery {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Battery", systemImage: "battery.100",
                              menuToggle: $menuBattery)
                batteryHealthHeadline(battery)
                ProgressView(value: min(max((battery.displayHealthPct ?? 0) / 100, 0), 1))
                    .tint(healthTint(battery.displayHealthPct))
                DisclosureGroup(isExpanded: $batteryExpanded) {
                    batteryDetails(battery)
                        .padding(.top, 4)
                } label: {
                    Text("Details")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func batteryHealthHeadline(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(battery.displayHealthPct.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("health")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                conditionBadge(battery.condition)
            }
            // Names where the headline came from. It must never show the
            // raw division here — macOS smooths its figure, so that division
            // yields a different number and reads as a contradiction.
            Text(healthSource(battery))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .help(healthHelp(battery))
    }

    /// Caption describing the headline's origin, so the number above is never
    /// unattributed.
    private func healthSource(_ battery: BatteryInfo) -> String {
        battery.appleMaxCapacityPct != nil
            ? "as reported by macOS"
            : "full-charge / design capacity"
    }

    private func healthHelp(_ battery: BatteryInfo) -> String {
        guard battery.appleMaxCapacityPct != nil else {
            return "Full-charge capacity divided by design capacity."
        }
        return "The same Maximum Capacity figure System Settings shows. macOS "
            + "smooths it, so it does not equal the plain full-charge / design "
            + "division — that raw ratio is listed separately below."
    }

    private func batteryDetails(_ battery: BatteryInfo) -> some View {
        VStack(spacing: 3) {
            batteryRow("Raw ratio", rawRatioText(battery),
                       help: "NominalChargeCapacity / DesignCapacity, computed here. "
                           + "macOS smooths this before publishing it, so it reads "
                           + "a little under the headline figure.")
            batteryRow("Full charge", mAh(battery.fullChargeCapacity),
                       help: "NominalChargeCapacity — what a full charge holds today")
            batteryRow("Design", mAh(battery.designCapacity),
                       help: "DesignCapacity — what the pack held when new")
            batteryRow("Raw max", rawMaxText(battery),
                       help: "AppleRawMaxCapacity — the gauge's own unsmoothed "
                           + "full-charge estimate, normally a little under the nominal one")
            batteryRow("Cycles", cyclesText(battery),
                       help: "CycleCount / DesignCycleCount9C")
            batteryRow("Charge", chargeText(battery),
                       help: "CurrentCapacity / AppleRawCurrentCapacity")
            batteryRow("Voltage", battery.voltage.map { String(format: "%.2f V", $0) } ?? "—",
                       help: "Voltage")
            batteryRow("Current", currentText(battery),
                       help: "Amperage — negative while discharging")
            batteryRow("Temperature",
                       battery.temperature.map { String(format: "%.1f °C", $0) } ?? "—",
                       help: "Temperature, reported in 1/100 °C")
            batteryRow("Power source", sourceText(battery), help: "ExternalConnected / IsCharging")
            if let minutes = battery.minutesRemaining {
                batteryRow(battery.isCharging ? "Time to full" : "Time to empty",
                           duration(minutes),
                           help: battery.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty")
            }
        }
    }

    private func batteryRow(_ label: String, _ value: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
        }
        .help(help)
    }

    private func conditionBadge(_ condition: String) -> some View {
        let normal = condition == "Normal"
        return Text(condition)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(normal ? Color.green : Color.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((normal ? Color.green : Color.orange).opacity(0.15)))
    }

    /// Apple treats 80% of design capacity as the service threshold.
    private func healthTint(_ pct: Double?) -> Color {
        guard let pct else { return .secondary }
        if pct >= 80 { return .green }
        if pct >= 60 { return .yellow }
        return .red
    }

    /// Self-contained so the division and its result always agree on screen.
    private func rawRatioText(_ battery: BatteryInfo) -> String {
        guard let pct = battery.healthPct else { return "—" }
        guard let full = battery.fullChargeCapacity,
              let design = battery.designCapacity else {
            return String(format: "%.1f%%", pct)
        }
        return String(format: "%d / %d = %.1f%%", full, design, pct)
    }

    private func mAh(_ value: Int?) -> String {
        value.map { "\($0) mAh" } ?? "—"
    }

    private func rawMaxText(_ battery: BatteryInfo) -> String {
        guard let raw = battery.rawMaxCapacity else { return "—" }
        guard let pct = battery.rawHealthPct else { return "\(raw) mAh" }
        return String(format: "%d mAh · %.1f%%", raw, pct)
    }

    private func cyclesText(_ battery: BatteryInfo) -> String {
        guard let count = battery.cycleCount else { return "—" }
        guard let design = battery.designCycleCount else { return "\(count)" }
        return "\(count) / \(design)"
    }

    private func chargeText(_ battery: BatteryInfo) -> String {
        let pct = battery.chargePct.map { String(format: "%.0f%%", $0) }
        switch (pct, battery.currentCapacity) {
        case let (pct?, capacity?): return "\(pct) · \(capacity) mAh"
        case let (pct?, nil):       return pct
        case let (nil, capacity?):  return "\(capacity) mAh"
        default:                    return "—"
        }
    }

    private func currentText(_ battery: BatteryInfo) -> String {
        guard let amperage = battery.amperage else { return "—" }
        guard let watts = battery.watts else { return "\(amperage) mA" }
        return String(format: "%d mA · %.1f W", amperage, watts)
    }

    private func sourceText(_ battery: BatteryInfo) -> String {
        if battery.isCharging { return "AC · charging" }
        if battery.fullyCharged && battery.externalConnected { return "AC · charged" }
        if battery.externalConnected { return "AC · not charging" }
        return "Battery"
    }

    private func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func tempTile(label: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("°C")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max((value ?? 0) / 100.0, 0), 1))
                .progressViewStyle(.linear)
                .tint(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var memSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Memory", systemImage: "memorychip", menuToggle: $menuMem)
            HStack {
                Text(String(format: "%.1f GB", snap.memUsedGB))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: "of %.1f GB", snap.memTotalGB))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", percent(snap.memUsedGB, snap.memTotalGB) * 100))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: percent(snap.memUsedGB, snap.memTotalGB))
                .tint(.green)
            Sparkline(series: [
                .init(values: snap.history.memPct, color: .green),
            ], yMax: 100)
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Disk", systemImage: "internaldrive", menuToggle: $menuDisk)
            HStack {
                Text(String(format: "%.1f GB used", snap.diskUsedGB))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: "· %.1f GB free", snap.diskFreeGB))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", percent(snap.diskUsedGB, snap.diskTotalGB) * 100))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: percent(snap.diskUsedGB, snap.diskTotalGB))
                .tint(.blue)
        }
    }

    private var netSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Network", systemImage: "antenna.radiowaves.left.and.right", menuToggle: $menuNet)
            HStack(spacing: 14) {
                netRow(icon: "arrow.down", label: "down", kbs: snap.netInKBs, color: .teal)
                netRow(icon: "arrow.up", label: "up", kbs: snap.netOutKBs, color: .pink)
            }
            Sparkline(series: [
                .init(values: snap.history.netIn,  color: .teal),
                .init(values: snap.history.netOut, color: .pink),
            ])
        }
    }

    private func netRow(icon: String, label: String, kbs: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(formatRate(kbs))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
    }

    private var footer: some View {
        HStack {
            Text("\(snap.allSensors.count) sensors")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onQuit) {
                Text(quitButtonTitle)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: helpers

    /// Section header with title on the left and (optionally) an inline menu-bar
    /// visibility toggle on the right.
    private func sectionHeader(_ text: String, systemImage: String,
                               menuToggle: Binding<Bool>?) -> some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            Spacer()
            if let menuToggle {
                Toggle("", isOn: menuToggle)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show in menu bar")
            }
        }
    }

    private func percent(_ used: Double, _ total: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(max(used / total, 0), 1)
    }

    private func formatRate(_ kbs: Double) -> String {
        if kbs >= 1024 {
            return String(format: "%.1f MB/s", kbs / 1024)
        }
        return String(format: "%.1f KB/s", kbs)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Compact, GPU-rendered sparkline. Renders one or more series right-aligned
/// across the history buffer; NaN samples create gaps. Auto-scales the y-axis
/// from the visible series unless `yMax` is supplied (e.g. 100 for percent).
struct Sparkline: View {
    struct Series { let values: [Float]; let color: Color }

    let series: [Series]
    var yMax: Float? = nil
    var height: CGFloat = 26

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let cap = StatsHistory.capacity
            let dx = size.width / CGFloat(max(cap - 1, 1))

            var maxV: Float = 0
            if let yMax {
                maxV = yMax
            } else {
                for s in series {
                    for v in s.values where v.isFinite && v > maxV { maxV = v }
                }
            }
            if maxV < 0.001 { maxV = 1 }

            for s in series {
                let n = s.values.count
                guard n > 1 else { continue }
                let xOffset = CGFloat(cap - n) * dx
                var path = Path()
                var started = false
                for i in 0..<n {
                    let v = s.values[i]
                    if !v.isFinite { started = false; continue }
                    let x = xOffset + CGFloat(i) * dx
                    let norm = min(max(CGFloat(v / maxV), 0), 1)
                    let y = size.height - norm * (size.height - 1) - 0.5
                    let p = CGPoint(x: x, y: y)
                    if started { path.addLine(to: p) }
                    else { path.move(to: p); started = true }
                }
                ctx.stroke(path, with: .color(s.color),
                           style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary.opacity(0.25)))
        .overlay(alignment: .topTrailing) {
            Text("5m")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 3)
        }
    }
}

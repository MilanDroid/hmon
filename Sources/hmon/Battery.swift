import Foundation
import IOKit

/// The values macOS derives battery health from, read from the
/// `AppleSmartBattery` IORegistry node and its `AppleSmartBatteryPack` child.
///
/// Capacities are in mAh, voltage in mV, amperage in mA (negative while
/// discharging), temperature in 1/100 °C — the raw units the gauge publishes.
///
/// Caveat worth knowing before trusting `healthPct` to match System Settings:
/// Settings shows a *smoothed* maximum-capacity figure that macOS caches in the
/// root-only `battery-health` NVRAM variable and updates slowly, so it can sit a
/// point or two away from the live ratio computed here. These are the gauge
/// inputs that figure is derived from, not the cached output.
struct BatteryInfo: Equatable {
    /// `DesignCapacity` — what the pack held when new.
    var designCapacity: Int?
    /// `NominalChargeCapacity` — what a full charge holds today. This over
    /// design capacity is the "Maximum Capacity" percentage Apple reports.
    var fullChargeCapacity: Int?
    /// `AppleRawMaxCapacity` — the gauge's own unsmoothed full-charge estimate,
    /// typically a little below the nominal figure.
    var rawMaxCapacity: Int?
    /// `AppleRawCurrentCapacity` — charge held right now.
    var currentCapacity: Int?

    /// `CurrentCapacity`, which on Apple Silicon is already a 0-100 percentage.
    var chargePct: Double?
    var cycleCount: Int?
    /// `DesignCycleCount9C` — the cycle rating the pack is warranted to.
    var designCycleCount: Int?

    var temperature: Double?   // °C
    var voltage: Double?       // volts
    var amperage: Int?         // mA, negative while discharging

    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    /// `PermanentFailureStatus` — non-zero once the gauge has condemned a cell.
    var permanentFailure = false

    var adapterWatts: Int?
    /// Minutes to full when charging, to empty when discharging. The gauge
    /// reports 65535 while it is still working the estimate out.
    var minutesRemaining: Int?

    var installed = false

    /// Apple's own "Maximum Capacity" figure — the one System Settings shows.
    /// Sourced from `system_profiler` (see `AppleBatteryHealth`) because the
    /// underlying API is entitlement-gated; nil until that first fetch lands.
    var appleMaxCapacityPct: Double?

    /// The health number to lead with: Apple's own figure when we have it,
    /// otherwise the live ratio computed here.
    var displayHealthPct: Double? {
        appleMaxCapacityPct ?? healthPct
    }

    /// Live ratio of today's full charge to the as-new design capacity. Apple
    /// smooths this before displaying it, so it normally reads a little lower
    /// than `appleMaxCapacityPct`.
    var healthPct: Double? {
        ratio(fullChargeCapacity, designCapacity)
    }

    /// The same ratio against the gauge's unsmoothed estimate. Shown alongside
    /// `healthPct` because the two disagreeing is normal, not a bug.
    var rawHealthPct: Double? {
        ratio(rawMaxCapacity, designCapacity)
    }

    /// How much of the pack's rated cycle life has been used.
    var cycleUsePct: Double? {
        ratio(cycleCount, designCycleCount)
    }

    /// Instantaneous pack power. Positive while charging, negative while the
    /// battery is supplying the machine.
    var watts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * Double(amperage) / 1000.0
    }

    /// Mirrors the Condition line in System Information: a gauge-flagged
    /// permanent failure, or wear past Apple's 80% service threshold.
    var condition: String {
        if permanentFailure { return "Service Recommended" }
        if let health = displayHealthPct, health < 80 { return "Service Recommended" }
        return "Normal"
    }

    private func ratio(_ value: Int?, _ total: Int?) -> Double? {
        guard let value, let total, total > 0 else { return nil }
        return Double(value) / Double(total) * 100
    }

    /// Reads every field above from the battery's IORegistry nodes. Returns nil
    /// on machines without a battery, so desktops simply show no section.
    static func read() -> BatteryInfo? {
        guard let battery = registryProperties(ofClass: "AppleSmartBattery") else {
            return nil
        }

        // Newer macOS (seen on 27.2) no longer publishes every value at the top
        // of the AppleSmartBattery node: the capacities moved into its nested
        // BatteryData, and temperature and failure status exist only in the
        // BatteryData of its child AppleSmartBatteryPack node. Sources are
        // merged in that order and the first one to have a key wins, so a
        // release that still publishes a key at the top reads exactly as before.
        let pack = registryProperties(ofClass: "AppleSmartBatteryPack")
        var props = battery
        props.merge(battery["BatteryData"] as? [String: Any] ?? [:]) { kept, _ in kept }
        props.merge(pack?["BatteryData"] as? [String: Any] ?? [:]) { kept, _ in kept }

        var info = BatteryInfo()
        info.installed = bool(props, "BatteryInstalled")
        guard info.installed else { return nil }

        info.designCapacity     = positive(props, "DesignCapacity")
        info.fullChargeCapacity = positive(props, "NominalChargeCapacity")
        info.rawMaxCapacity     = positive(props, "AppleRawMaxCapacity")
        info.currentCapacity    = positive(props, "AppleRawCurrentCapacity")
        info.cycleCount         = int(props, "CycleCount")
        info.designCycleCount   = positive(props, "DesignCycleCount9C")
        info.amperage           = int(props, "Amperage")

        if let pct = int(props, "CurrentCapacity"), (0...100).contains(pct) {
            info.chargePct = Double(pct)
        }
        // 1/100 °C. Bound-checked because the key reads back as 0 on a pack the
        // SMC hasn't published yet.
        if let raw = int(props, "Temperature") {
            let celsius = Double(raw) / 100.0
            if celsius > 0, celsius < 150 { info.temperature = celsius }
        }
        if let millivolts = positive(props, "Voltage") {
            info.voltage = Double(millivolts) / 1000.0
        }

        info.isCharging        = bool(props, "IsCharging")
        info.externalConnected = bool(props, "ExternalConnected")
        info.fullyCharged      = bool(props, "FullyCharged")
        info.permanentFailure  = (int(props, "PermanentFailureStatus") ?? 0) != 0

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            info.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
        }

        // The gauge parks these at 65535 until it has a confident estimate.
        let remaining = int(props, info.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty")
        if let remaining, remaining > 0, remaining < 65535 {
            info.minutesRemaining = remaining
        }

        return info
    }

    /// Every property of the first IORegistry node of the given class, or nil
    /// when there is no such node (a Mac without a battery has neither).
    private static func registryProperties(ofClass className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
                service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    private static func int(_ props: [String: Any], _ key: String) -> Int? {
        (props[key] as? NSNumber)?.intValue
    }

    /// Several keys read back as 0 rather than absent when unavailable; treat
    /// those as missing so the UI shows a dash instead of a bogus zero.
    private static func positive(_ props: [String: Any], _ key: String) -> Int? {
        guard let value = int(props, key), value > 0 else { return nil }
        return value
    }

    private static func bool(_ props: [String: Any], _ key: String) -> Bool {
        (props[key] as? NSNumber)?.boolValue ?? false
    }
}

/// Apple's "Maximum Capacity" percentage, which macOS computes with
/// `IOPSCopyPowerSourcesByTypePrecise`.
///
/// That call is gated behind the private `com.apple.private.iokit.batterydataprecise`
/// entitlement — verified with `codesign -d --entitlements`, and calling it
/// unentitled returns `kIOReturnNotPrivileged`. Apple only grants such
/// entitlements to its own signed binaries, so no third-party app can read the
/// value directly. `/usr/sbin/system_profiler` does hold it, so we ask that
/// instead. It costs ~0.13 s per run, and the figure only moves over days, so
/// callers refresh it on a slow cadence rather than per tick.
enum AppleBatteryHealth {
    /// Runs system_profiler and returns the percentage, e.g. 88.0. Blocking —
    /// never call this from the main thread.
    static func maximumCapacityPct() -> Double? {
        guard let json = runSystemProfiler(),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]]
        else { return nil }

        for entry in entries {
            guard let health = entry["sppower_battery_health_info"] as? [String: Any],
                  let raw = health["sppower_battery_health_maximum_capacity"] as? String
            else { continue }
            // Reported as a display string like "88%".
            let digits = raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            if let pct = Double(digits), pct > 0, pct <= 100 { return pct }
        }
        return nil
    }

    private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Output is a few KB, so draining before waiting cannot deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}

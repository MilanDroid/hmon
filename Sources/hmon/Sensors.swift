import Foundation
import IOKit

// Apple Silicon thermal sensors are exposed via the private IOHIDEventSystemClient
// API. We resolve the symbols at runtime so the binary still links cleanly.

private typealias IOHIDEventSystemClientCreateFn =
    @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
private typealias IOHIDEventSystemClientSetMatchingFn =
    @convention(c) (AnyObject, CFDictionary) -> Int32
private typealias IOHIDEventSystemClientCopyServicesFn =
    @convention(c) (AnyObject) -> Unmanaged<CFArray>?
private typealias IOHIDServiceClientCopyPropertyFn =
    @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
private typealias IOHIDServiceClientCopyEventFn =
    @convention(c) (AnyObject, Int64, Int32, UInt64) -> Unmanaged<AnyObject>?
private typealias IOHIDEventGetFloatValueFn =
    @convention(c) (AnyObject, Int32) -> Double

private let kIOHIDEventTypeTemperature: Int32 = 15
private let kTempFieldLevel: Int32 = kIOHIDEventTypeTemperature << 16

enum Sensors {
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    }()

    private static func sym<T>(_ name: String, _ as: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let create = sym("IOHIDEventSystemClientCreate",
                                    IOHIDEventSystemClientCreateFn.self)
    private static let setMatching = sym("IOHIDEventSystemClientSetMatching",
                                         IOHIDEventSystemClientSetMatchingFn.self)
    private static let copyServices = sym("IOHIDEventSystemClientCopyServices",
                                          IOHIDEventSystemClientCopyServicesFn.self)
    private static let copyProperty = sym("IOHIDServiceClientCopyProperty",
                                          IOHIDServiceClientCopyPropertyFn.self)
    private static let copyEvent = sym("IOHIDServiceClientCopyEvent",
                                       IOHIDServiceClientCopyEventFn.self)
    private static let eventFloat = sym("IOHIDEventGetFloatValue",
                                        IOHIDEventGetFloatValueFn.self)

    private static let client: AnyObject? = {
        guard let create, let setMatching else { return nil }
        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // kHIDPage_AppleVendor = 0xff00, kHIDUsage_AppleVendor_TemperatureSensor = 0x0005
        let match: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x0005,
        ]
        _ = setMatching(c, match as CFDictionary)
        return c
    }()

    struct Reading {
        let name: String
        let celsius: Double
    }

    static func readAll() -> [Reading] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let eventFloat
        else { return [] }
        guard let servicesRef = copyServices(client) else { return [] }
        let services = servicesRef.takeRetainedValue() as [AnyObject]

        var out: [Reading] = []
        for service in services {
            let nameRef = copyProperty(service, "Product" as CFString)
            let name = (nameRef?.takeRetainedValue() as? String) ?? ""
            guard let eventRef = copyEvent(service, Int64(kIOHIDEventTypeTemperature), 0, 0)
            else { continue }
            let event = eventRef.takeRetainedValue()
            let value = eventFloat(event, kTempFieldLevel)
            guard value.isFinite, value > 0, value < 150 else { continue }
            out.append(Reading(name: name, celsius: value))
        }
        return out
    }

    enum VisualKind { case cpu, gpu, other }

    /// Broader, name-only classifier used purely to badge sensor rows in the
    /// UI — independent of the temperature calculation. Catches PMU/cluster
    /// probes that the calc deliberately ignores (tcal, tdev), so users see
    /// the silicon family for every row.
    static func visualKind(of name: String) -> VisualKind {
        let n = name.lowercased()
        if n.contains("gpu") { return .gpu }
        if n.hasPrefix("pmu2") { return .gpu }
        if n.contains("cpu") || n.contains("pacc") || n.contains("eacc")
            || n.contains("pcpu") || n.contains("ecpu") { return .cpu }
        if n.hasPrefix("pmu ") || n.hasPrefix("pmu1") { return .cpu }
        return .other
    }

    struct Classification {
        let cpu: Double?
        let gpu: Double?
        let cpuNames: Set<String>
        let gpuNames: Set<String>
    }

    /// Returns the hottest CPU/GPU temperatures plus the set of sensor names
    /// that were considered — useful for surfacing the source readings.
    ///
    /// Apple Silicon sensor names fall into two conventions:
    ///   Old (M1): explicit names — pACC/eACC MTR, GPU MTR, ANE MTR, SOC MTR
    ///   New (M2+): power-management probes — "PMU tdie1", "PMU2 tcal", etc.
    /// On chips with two PMUs the convention is PMU = main SoC (CPU side),
    /// PMU2 = secondary/GPU power island.
    static func classify(_ readings: [Reading]) -> Classification {
        var cpuVals: [Double] = []
        var gpuVals: [Double] = []
        var cpuNames: Set<String> = []
        var gpuNames: Set<String> = []
        for r in readings {
            let n = r.name.lowercased()

            // New-style PMU probes — only the die readings. "tcal" is a
            // calibration reading (not a true die temp) and "tdev" is a
            // board-level device temp — both excluded from the average,
            // but still surfaced in the full sensor list.
            if n.contains("tdie") {
                if n.hasPrefix("pmu2 ") {
                    gpuVals.append(r.celsius); gpuNames.insert(r.name); continue
                }
                if n.hasPrefix("pmu ") {
                    cpuVals.append(r.celsius); cpuNames.insert(r.name); continue
                }
            }

            // Old-style explicit names (M1 generation).
            if n.contains("gpu") {
                gpuVals.append(r.celsius); gpuNames.insert(r.name)
            } else if n.contains("pacc") || n.contains("eacc")
                        || n.contains("pcpu") || n.contains("ecpu")
                        || n.contains("cpu") {
                cpuVals.append(r.celsius); cpuNames.insert(r.name)
            }
        }
        return Classification(cpu: cpuVals.max(), gpu: gpuVals.max(),
                              cpuNames: cpuNames, gpuNames: gpuNames)
    }

    /// Writes every sensor name to /tmp/hmon-sensors.txt so unfamiliar chips
    /// can be inspected directly.
    static func dumpNamesOnce() {
        guard !didDump else { return }
        didDump = true
        let readings = readAll()
        var out = "hmon sensor dump (\(readings.count) sensors)\n"
        out += "================================\n"
        for r in readings {
            out += String(format: "%-40s  %6.2f°C\n", (r.name as NSString).utf8String!, r.celsius)
        }
        try? out.write(toFile: "/tmp/hmon-sensors.txt", atomically: true, encoding: .utf8)
    }

    private static var didDump = false
}

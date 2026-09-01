import Foundation
import Combine

struct StatsSnapshot {
    var cpuTemp: Double? = nil
    var gpuTemp: Double? = nil
    var batteryTemp: Double? = nil
    var battery: BatteryInfo? = nil
    var cpuUsePct: Double = 0
    var cpuPerCorePct: [Double] = []
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
    var diskUsedGB: Double = 0
    var diskFreeGB: Double = 0
    var diskTotalGB: Double = 0
    var netInKBs: Double = 0
    var netOutKBs: Double = 0
    var allSensors: [Sensors.Reading] = []
    var cpuSensorNames: Set<String> = []
    var gpuSensorNames: Set<String> = []
    var history = StatsHistory()
}

/// Ring buffer of recent samples for compact sparklines. Float for memory size;
/// NaN marks a gap (datum wasn't collected that tick).
struct StatsHistory {
    /// 5 minutes at the 2 s tick.
    static let capacity = 150

    var cpuTemp:    [Float] = []
    var gpuTemp:    [Float] = []
    var battTemp:   [Float] = []
    var cpuUse:     [Float] = []
    var cpuPerCore: [[Float]] = []
    var memPct:     [Float] = []
    var netIn:      [Float] = []
    var netOut:     [Float] = []

    mutating func append(cpu: Double?, gpu: Double?, battery: Double?,
                         cpuUseTotal cuTotal: Double?,
                         cpuUsePerCore cuPer: [Double]?,
                         memPct mp: Double,
                         netIn ni: Double, netOut no: Double) {
        let cap = Self.capacity
        if cpuTemp.count >= cap { cpuTemp.removeFirst() }
        cpuTemp.append(cpu.map(Float.init) ?? .nan)
        if gpuTemp.count >= cap { gpuTemp.removeFirst() }
        gpuTemp.append(gpu.map(Float.init) ?? .nan)
        if battTemp.count >= cap { battTemp.removeFirst() }
        battTemp.append(battery.map(Float.init) ?? .nan)
        if cpuUse.count >= cap { cpuUse.removeFirst() }
        cpuUse.append(cuTotal.map(Float.init) ?? .nan)
        let per = cuPer ?? []
        if cpuPerCore.count != per.count {
            cpuPerCore = Array(repeating: [Float](), count: per.count)
        }
        for i in 0..<per.count {
            if cpuPerCore[i].count >= cap { cpuPerCore[i].removeFirst() }
            cpuPerCore[i].append(Float(per[i]))
        }
        if memPct.count  >= cap { memPct.removeFirst() }
        memPct.append(Float(mp))
        if netIn.count   >= cap { netIn.removeFirst() }
        netIn.append(Float(ni))
        if netOut.count  >= cap { netOut.removeFirst() }
        netOut.append(Float(no))
    }
}

enum Prefs {
    // Menu-bar item toggles (popover always shows everything when open).
    static let menuTemp = "menuTemp"
    static let menuMem = "menuMem"
    static let menuNet = "menuNet"
    static let menuCPU = "menuCPU"
    static let menuDisk = "menuDisk"
    static let menuBattery = "menuBattery"
    static let desktopWidget = "desktopWidget"

    /// Defaults to `true` when the key has never been written.
    static func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

final class StatsModel: ObservableObject {
    /// Latest values. Plain var — not @Published, so menu-bar updates don't drag
    /// SwiftUI through a body re-evaluation. Read & written only on main.
    private(set) var snapshot = StatsSnapshot()

    /// SwiftUI-observable mirror. Only assigned while the popover is open, so the
    /// hidden view tree isn't churned every tick.
    @Published var live = StatsSnapshot()

    /// Fires once per tick on main, after `snapshot` has been updated.
    var onTick: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "hmon.stats", qos: .utility)
    private var lastNet: SystemStats.NetIO?
    private var lastCPU: SystemStats.CPUSample?
    private var lastSample = Date()
    private var tickCount: UInt64 = 0
    private var popoverActive = false        // mutated only on `queue`
    private var widgetActive  = false        // mutated only on `queue`
    private var cachedDisk: SystemStats.Disk?
    private var cachedTemps: Sensors.Classification =
        Sensors.Classification(cpu: nil, gpu: nil, cpuNames: [], gpuNames: [])
    private var cachedBattery: BatteryInfo?
    /// Apple's smoothed maximum-capacity figure. Fetched by shelling out to the
    /// entitled `system_profiler`, so it lives on its own slow cadence and its
    /// own queue — never on the 2 s tick. Mutated only on `queue`.
    private var appleHealthPct: Double?
    private var appleHealthFetchedAt: Date?
    private var appleHealthFetchInFlight = false
    private let profilerQueue = DispatchQueue(label: "hmon.systemprofiler", qos: .utility)
    /// Battery wear is a multi-day process; re-asking more often than this
    /// would just be spawning processes for nothing.
    private static let appleHealthMaxAge: TimeInterval = 15 * 60

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func setPopoverActive(_ active: Bool) {
        queue.async { [weak self] in
            self?.popoverActive = active
            if active { self?.refreshNow() }
        }
    }

    func setWidgetActive(_ active: Bool) {
        queue.async { [weak self] in
            self?.widgetActive = active
            if active { self?.refreshNow() }
        }
    }

    /// Synchronous full refresh on the stats queue. Used when a live consumer
    /// turns on so it doesn't have to wait for the next 2 s tick.
    private func refreshNow() {
        let readings = Sensors.readAll()
        let classified = self.classifyWithFallback(readings)
        self.cachedTemps = classified
        refreshAppleHealthIfStale()
        var battery = BatteryInfo.read()
        battery?.appleMaxCapacityPct = self.appleHealthPct
        self.cachedBattery = battery
        let sorted = readings.sorted { $0.name < $1.name }
        let mem = SystemStats.memory()
        let disk = SystemStats.disk()
        self.cachedDisk = disk
        DispatchQueue.main.async {
            self.snapshot.allSensors = sorted
            self.snapshot.cpuTemp = classified.cpu
            self.snapshot.gpuTemp = classified.gpu
            self.snapshot.batteryTemp = battery?.temperature
            self.snapshot.battery = battery
            self.snapshot.cpuSensorNames = classified.cpuNames
            self.snapshot.gpuSensorNames = classified.gpuNames
            self.snapshot.memUsedGB = mem.usedGB
            self.snapshot.memTotalGB = mem.totalGB
            self.snapshot.diskUsedGB = disk.usedGB
            self.snapshot.diskFreeGB = disk.freeGB
            self.snapshot.diskTotalGB = disk.totalGB
            self.live = self.snapshot
        }
    }

    private func tick() {
        tickCount &+= 1
        let now = Date()
        let dt = max(now.timeIntervalSince(lastSample), 0.001)
        lastSample = now

        // A datum is fetched if either the menu bar wants it or a live consumer
        // (popover / desktop widget) is showing.
        let live = popoverActive || widgetActive
        let wantTemp    = Prefs.enabled(Prefs.menuTemp) || live
        let wantMem     = Prefs.enabled(Prefs.menuMem)  || live
        let wantNet     = Prefs.enabled(Prefs.menuNet)  || live
        let wantCPU     = Prefs.enabled(Prefs.menuCPU)  || live
        let wantDisk    = Prefs.enabled(Prefs.menuDisk) || live
        let wantBattery = Prefs.enabled(Prefs.menuBattery) || live
        let wantSensors = live

        var memOut: SystemStats.Memory? = nil
        if wantMem {
            memOut = SystemStats.memory()
        }

        var inKBs = 0.0
        var outKBs = 0.0
        if wantNet {
            let net = SystemStats.netCounters()
            if let last = lastNet {
                inKBs = max(0, Double(net.bytesIn &- last.bytesIn) / dt / 1024.0)
                outKBs = max(0, Double(net.bytesOut &- last.bytesOut) / dt / 1024.0)
            }
            lastNet = net
        } else {
            lastNet = nil  // reset so re-enable doesn't show a bogus spike
        }

        var cpuLoad: SystemStats.CPULoad? = nil
        if wantCPU {
            if let curr = SystemStats.cpuSample() {
                cpuLoad = SystemStats.cpuLoad(prev: lastCPU, curr: curr)
                lastCPU = curr
            }
        } else {
            lastCPU = nil  // reset so re-enable doesn't show a stale delta
        }

        var diskOut: SystemStats.Disk? = nil
        if wantDisk {
            if cachedDisk == nil || tickCount % 5 == 0 {
                cachedDisk = SystemStats.disk()
            }
            diskOut = cachedDisk
        } else {
            cachedDisk = nil
        }

        // One IORegistry round trip (~0.4 ms). Health barely moves, so back off
        // to every 5th tick (10 s) when only the menu bar is watching.
        if wantBattery {
            refreshAppleHealthIfStale()
            if live || cachedBattery == nil || tickCount % 5 == 0 {
                var battery = BatteryInfo.read()
                battery?.appleMaxCapacityPct = appleHealthPct
                cachedBattery = battery
            }
        } else {
            cachedBattery = nil
        }

        // IOKit sensor enumeration is the most expensive call here. Halve its
        // rate while the popover is closed (temps barely move in 4s). Skip
        // entirely when temp + sensors-list are both disabled.
        let needReadAll =
            (wantTemp && (live || tickCount % 2 == 0))
            || (wantSensors && live)
        var sortedSensors: [Sensors.Reading]? = nil
        if needReadAll {
            let readings = Sensors.readAll()
            if wantTemp {
                cachedTemps = classifyWithFallback(readings)
            }
            if wantSensors && live {
                sortedSensors = readings.sorted { $0.name < $1.name }
            }
        }
        if !wantTemp {
            cachedTemps = Sensors.Classification(
                cpu: nil, gpu: nil, cpuNames: [], gpuNames: [])
        }
        let temps = cachedTemps
        let battery = cachedBattery
        let publishLive = live

        DispatchQueue.main.async {
            self.snapshot.cpuTemp = temps.cpu
            self.snapshot.gpuTemp = temps.gpu
            self.snapshot.batteryTemp = battery?.temperature
            self.snapshot.battery = battery
            self.snapshot.cpuSensorNames = temps.cpuNames
            self.snapshot.gpuSensorNames = temps.gpuNames
            if let memOut {
                self.snapshot.memUsedGB = memOut.usedGB
                self.snapshot.memTotalGB = memOut.totalGB
            } else {
                self.snapshot.memUsedGB = 0
                self.snapshot.memTotalGB = 0
            }
            if let diskOut {
                self.snapshot.diskUsedGB = diskOut.usedGB
                self.snapshot.diskFreeGB = diskOut.freeGB
                self.snapshot.diskTotalGB = diskOut.totalGB
            } else {
                self.snapshot.diskUsedGB = 0
                self.snapshot.diskFreeGB = 0
                self.snapshot.diskTotalGB = 0
            }
            self.snapshot.netInKBs = inKBs
            self.snapshot.netOutKBs = outKBs
            if let cpuLoad {
                self.snapshot.cpuUsePct = cpuLoad.totalPct
                self.snapshot.cpuPerCorePct = cpuLoad.perCorePct
            } else if !wantCPU {
                self.snapshot.cpuUsePct = 0
                self.snapshot.cpuPerCorePct = []
            }
            if let sortedSensors {
                self.snapshot.allSensors = sortedSensors
            } else if !wantSensors {
                self.snapshot.allSensors = []
            }
            let mp: Double = self.snapshot.memTotalGB > 0
                ? self.snapshot.memUsedGB / self.snapshot.memTotalGB * 100
                : .nan
            self.snapshot.history.append(
                cpu: wantTemp ? temps.cpu : nil,
                gpu: wantTemp ? temps.gpu : nil,
                battery: wantBattery ? battery?.temperature : nil,
                cpuUseTotal:   cpuLoad?.totalPct,
                cpuUsePerCore: cpuLoad?.perCorePct,
                memPct: wantMem ? mp : .nan,
                netIn:  wantNet ? inKBs : .nan,
                netOut: wantNet ? outKBs : .nan)
            if publishLive {
                self.live = self.snapshot
            }
            self.onTick?()
        }
    }

    /// Kicks off a `system_profiler` fetch when the cached figure has aged out.
    /// Must be called on `queue`; the spawn itself happens elsewhere so a 0.13 s
    /// process launch never stalls the tick.
    private func refreshAppleHealthIfStale() {
        guard !appleHealthFetchInFlight else { return }
        if let fetchedAt = appleHealthFetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.appleHealthMaxAge { return }
        appleHealthFetchInFlight = true
        profilerQueue.async { [weak self] in
            let pct = AppleBatteryHealth.maximumCapacityPct()
            self?.queue.async {
                guard let self else { return }
                self.appleHealthFetchInFlight = false
                self.appleHealthFetchedAt = Date()
                if let pct { self.appleHealthPct = pct }
            }
        }
    }

    private func classifyWithFallback(_ readings: [Sensors.Reading]) -> Sensors.Classification {
        let c = Sensors.classify(readings)
        if c.cpu == nil && c.gpu == nil && !readings.isEmpty {
            let hottest = readings.map(\.celsius).max() ?? 0
            return Sensors.Classification(
                cpu: hottest, gpu: nil,
                cpuNames: Set(readings.map(\.name)), gpuNames: [])
        }
        return c
    }
}

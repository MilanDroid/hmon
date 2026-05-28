import Foundation
import Darwin

enum SystemStats {
    // MARK: Memory

    struct Memory {
        let usedGB: Double
        let totalGB: Double
    }

    static func memory() -> Memory {
        var size: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &sz, nil, 0)
        let total = Double(size)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Memory(usedGB: 0, totalGB: total / 1_073_741_824)
        }
        let pageSize = Double(vm_kernel_page_size)
        // Activity Monitor "Memory Used" = total − Free − Cached Files.
        // Cached Files ≈ external_page_count (file-backed reusable pages).
        let free = Double(stats.free_count) * pageSize
        let speculative = Double(stats.speculative_count) * pageSize
        let cached = Double(stats.external_page_count) * pageSize
        let used = max(total - free - speculative - cached, 0)
        return Memory(usedGB: used / 1_073_741_824, totalGB: total / 1_073_741_824)
    }

    // MARK: Disk

    struct Disk {
        let usedGB: Double
        let freeGB: Double
        let totalGB: Double
    }

    static func disk(path: String = "/") -> Disk {
        // Use Finder's convention: decimal GB (1e9 bytes) and purgeable-aware free space.
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let gb = 1_000_000_000.0
        if let values = try? url.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity,
           let available = values.volumeAvailableCapacityForImportantUsage {
            let totalD = Double(total)
            let freeD = Double(available)
            let used = max(totalD - freeD, 0)
            return Disk(usedGB: used / gb, freeGB: freeD / gb, totalGB: totalD / gb)
        }
        var s = statfs()
        guard statfs(path, &s) == 0 else { return Disk(usedGB: 0, freeGB: 0, totalGB: 0) }
        let bs = Double(s.f_bsize)
        let total = Double(s.f_blocks) * bs
        let free = Double(s.f_bavail) * bs
        return Disk(usedGB: (total - free) / gb, freeGB: free / gb, totalGB: total / gb)
    }

    // MARK: CPU load

    /// Raw scheduler-tick counters from `host_processor_info`, one entry per
    /// logical CPU. Percentages are produced by diffing two samples.
    struct CPUSample {
        struct Ticks { let user: UInt64; let system: UInt64; let idle: UInt64; let nice: UInt64 }
        let perCore: [Ticks]
    }

    static func cpuSample() -> CPUSample? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let r = host_processor_info(mach_host_self(),
                                    PROCESSOR_CPU_LOAD_INFO,
                                    &cpuCount, &info, &infoCount)
        guard r == KERN_SUCCESS, let info else { return nil }
        defer {
            let bytes = vm_size_t(MemoryLayout<integer_t>.stride) * vm_size_t(infoCount)
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          bytes)
        }
        let stride = Int(CPU_STATE_MAX)
        var cores: [CPUSample.Ticks] = []
        cores.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            cores.append(.init(
                user:   UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                idle:   UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                nice:   UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))))
        }
        return CPUSample(perCore: cores)
    }

    struct CPULoad {
        let totalPct: Double
        let perCorePct: [Double]
    }

    /// Per-core busy% (and overall mean) between two samples. Tolerant of an
    /// `nil` previous sample (returns zeros) and counter wraps.
    static func cpuLoad(prev: CPUSample?, curr: CPUSample) -> CPULoad {
        guard let prev, prev.perCore.count == curr.perCore.count, !curr.perCore.isEmpty else {
            return CPULoad(totalPct: 0,
                           perCorePct: Array(repeating: 0, count: curr.perCore.count))
        }
        var per: [Double] = []
        per.reserveCapacity(curr.perCore.count)
        var sum = 0.0
        for i in 0..<curr.perCore.count {
            let c = curr.perCore[i], p = prev.perCore[i]
            let du = c.user   &- p.user
            let ds = c.system &- p.system
            let dn = c.nice   &- p.nice
            let di = c.idle   &- p.idle
            let busy = du &+ ds &+ dn
            let total = busy &+ di
            let pct = total > 0 ? Double(busy) / Double(total) * 100 : 0
            per.append(pct)
            sum += pct
        }
        return CPULoad(totalPct: sum / Double(per.count), perCorePct: per)
    }

    // MARK: Network throughput

    struct NetIO {
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    static func netCounters() -> NetIO {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return NetIO(bytesIn: 0, bytesOut: 0) }
        defer { freeifaddrs(ifap) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                // Skip loopback and virtual interfaces — we want real net traffic
                if !name.hasPrefix("lo") && !name.hasPrefix("gif") && !name.hasPrefix("stf")
                    && !name.hasPrefix("utun") && !name.hasPrefix("awdl")
                    && !name.hasPrefix("llw") && !name.hasPrefix("anpi")
                    && !name.hasPrefix("ap") && !name.hasPrefix("bridge") {
                    if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        totalIn &+= UInt64(data.pointee.ifi_ibytes)
                        totalOut &+= UInt64(data.pointee.ifi_obytes)
                    }
                }
            }
            p = ifa.ifa_next
        }
        return NetIO(bytesIn: totalIn, bytesOut: totalOut)
    }
}

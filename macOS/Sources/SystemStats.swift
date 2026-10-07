import Darwin
import Foundation
import IOKit.ps

@MainActor
final class SystemStats: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var topProcess = "—"
    @Published var memPercent: Double = 0
    @Published var memUsedGB: Double = 0
    @Published var memTotalGB: Double = 0
    @Published var batteryPercent: Int?
    @Published var batteryCharging = false

    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastBattery = Date.distantPast
    private var lastTop = Date.distantPast
    private var topPrev: [pid_t: UInt64] = [:]
    private var topPrevDate = Date()
    private var task: Task<Void, Never>?

    static let shared = SystemStats()

    func start() {
        guard task == nil else { return }
        memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        if Date().timeIntervalSince(lastBattery) >= 20 {
            lastBattery = Date()
            sampleBattery()
        }
        if Date().timeIntervalSince(lastTop) >= 10 {
            lastTop = Date()
            sampleTopProcess()
        }
    }

    private func sampleCPU() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        if let prev = prevTicks {
            let du = user - prev.user, ds = system - prev.system
            let di = idle - prev.idle, dn = nice - prev.nice
            let total = du + ds + di + dn
            if total > 0 {
                let busy = Double(du + ds + dn) / Double(total) * 100
                let clamped = min(100, max(0, busy))
                // solo publica si cambió bastante: evita redibujos continuos
                if abs(clamped - cpuPercent) >= 0.5 || (clamped == 0) != (cpuPercent == 0) {
                    cpuPercent = clamped
                }
            }
        }
        prevTicks = (user, system, idle, nice)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, memTotalGB > 0 else { return }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)
        let pct = min(100, Double(used) / Double(total) * 100)
        if abs(pct - memPercent) >= 0.5 {
            memUsedGB = Double(used) / 1_073_741_824
            memPercent = pct
        }
    }

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any],
                let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            batteryPercent = Int(Double(cur) / Double(max) * 100)
            batteryCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return
        }
    }

    /// Top process vía sysctl (sin crear procesos auxiliares).
    private func sampleTopProcess() {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride
        guard count > 0 else { return }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return }
        let realCount = size / stride

        let now = Date()
        let interval = max(now.timeIntervalSince(topPrevDate), 0.5)
        let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)

        var current: [pid_t: UInt64] = [:]
        var bestPid: pid_t = 0
        var bestPct = 0.0
        let old = topPrev

        for i in 0..<realCount {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }
            var info = proc_taskinfo()
            let got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                   Int32(MemoryLayout<proc_taskinfo>.stride))
            guard got == MemoryLayout<proc_taskinfo>.stride else { continue }
            let total = info.pti_total_user &+ info.pti_total_system
            current[pid] = total
            if let prev = old[pid], total >= prev {
                let delta = total - prev
                let pct = Double(delta) / (interval * 1_000_000_000 * ncpu) * 100
                if pct > bestPct {
                    bestPct = pct
                    bestPid = pid
                }
            }
        }

        if bestPid > 0 {
            let bestName = processName(pid: bestPid)
            let shown = min(99.9, bestPct)
            topProcess = "\(bestName) (\(String(format: "%.0f", shown))%)"
        }

        topPrev = current
        topPrevDate = now
    }

    private func processName(pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        if len > 0 {
            let path = String(cString: buf)
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }
}

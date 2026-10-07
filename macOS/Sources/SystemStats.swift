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
    private var task: Task<Void, Never>?

    static let shared = SystemStats()

    func start() {
        guard task == nil else { return }
        memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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
        sampleBattery()
        sampleTopProcess()
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
                cpuPercent = min(100, max(0, busy))
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
        memUsedGB = Double(used) / 1_073_741_824
        memPercent = min(100, Double(used) / Double(total) * 100)
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

    private func sampleTopProcess() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "%cpu,comm", "-r"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        if lines.count > 1 {
            let first = String(lines[1]).trimmingCharacters(in: .whitespaces)
            let parts = first.split(separator: " ", maxSplits: 1)
            if parts.count == 2 {
                let name = URL(fileURLWithPath: String(parts[1])).lastPathComponent
                topProcess = "\(name) (\(parts[0])%)"
            }
        }
    }
}

import AppKit
import Darwin
import Foundation

@MainActor
enum SystemOptimizer {

    // ---------------------------------------------------------- memoria

    static func availableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        // memoria que el kernel puede reasignar sin swap: libre + inactiva + purgable
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count)) * pageSize
    }

    static func freeMemory() -> String {
        let before = availableBytes()
        let total = ProcessInfo.processInfo.physicalMemory
        // reclama ~25% de la RAM: al tocar las páginas, el kernel comprime/inactiva lo demás
        var size = Int(total / 4)
        while size > 64 * 1_048_576 {
            if let ptr = malloc(size) {
                memset(ptr, 0xA5, size)
                // toca cada 64 KB además del memset inicial (fuerza la residentia)
                var off = 0
                while off < size {
                    ptr.storeBytes(of: UInt8(1), toByteOffset: off, as: UInt8.self)
                    off += 65_536
                }
                free(ptr)
                break
            }
            size /= 2
        }
        let after = availableBytes()
        let gained = Int64(after) - Int64(before)
        let fmt: (UInt64) -> String = { String(format: "%.2f GB", Double($0) / 1_073_741_824) }
        if gained > 32 * 1_048_576 {
            return "Memoria liberada: +\(fmt(after - before)) disponibles (\(fmt(before)) → \(fmt(after)))."
        }
        return "Memoria ya bastante libre: \(fmt(after)) disponibles."
    }

    // ---------------------------------------------------------- temporales

    private static func cleanDirectory(_ url: URL, olderThanDays: Int) -> (files: Int, bytes: Int64) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        var files = 0
        var bytes: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return (0, 0) }
        var toDelete: [URL] = []
        var depth = 0
        while let item = enumerator.nextObject() as? URL {
            depth += 1
            if depth > 4000 { break }
            guard let values = try? item.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
            ) else { continue }
            if values.isDirectory == true { continue }
            if let mod = values.contentModificationDate, mod < cutoff {
                toDelete.append(item)
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        for item in toDelete {
            if (try? fm.removeItem(at: item)) != nil { files += 1 }
        }
        return (files, bytes)
    }

    static func cleanTemps() -> String {
        var files = 0
        var bytes: Int64 = 0

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let r1 = cleanDirectory(tmp, olderThanDays: 7)
        files += r1.files
        bytes += r1.bytes

        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let r2 = cleanDirectory(caches, olderThanDays: 7)
            files += r2.files
            bytes += r2.bytes
        }

        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        if files == 0 {
            return "No había temporales viejos que limpiar (se conservan los de menos de 7 días)."
        }
        return "Limpieza: \(files) archivos viejos eliminados (\(fmt.string(fromByteCount: bytes)))."
    }

    // ---------------------------------------------------------- papelera

    static func emptyTrash() -> String {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
            return "La Papelera ya está vacía."
        }
        var removed = 0
        for item in items {
            if (try? fm.removeItem(at: item)) != nil { removed += 1 }
        }
        if removed == 0 { return "La Papelera ya está vacía." }
        return "Papelera vaciada: \(removed) elemento(s)."
    }
}

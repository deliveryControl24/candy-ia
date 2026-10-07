import Foundation

struct ServiceCheck: Codable {
    let at: Date
    let ok: Bool
    let ms: Int
}

struct MonitoredService: Identifiable, Codable {
    var id: String { name }
    let name: String
    var url: String
    var checks: [ServiceCheck]
}

@MainActor
final class ServicesMonitor: ObservableObject {
    @Published var services: [MonitoredService] = []

    static let shared = ServicesMonitor()
    private var monitorTask: Task<Void, Never>?
    private static let maxChecks = 500

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CandyIA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("services.json")
    }

    private init() {
        load()
    }

    func startMonitoring() {
        guard monitorTask == nil, !services.isEmpty else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func register(name: String, url: String) async -> MonitoredService {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanURL = url.trimmingCharacters(in: .whitespaces)
        if let idx = services.firstIndex(where: {
            $0.name.lowercased() == cleanName.lowercased()
        }) {
            if services[idx].url != cleanURL {
                services[idx].url = cleanURL
            }
            await check(index: idx)
            save()
            startMonitoring()
            return services[idx]
        }
        services.append(MonitoredService(name: cleanName, url: cleanURL, checks: []))
        await check(index: services.count - 1)
        save()
        startMonitoring()
        return services[services.count - 1]
    }

    func remove(name: String) -> Bool {
        guard let idx = services.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) else { return false }
        services.remove(at: idx)
        save()
        return true
    }

    func refreshAll() async {
        for i in services.indices {
            await check(index: i)
        }
        if !services.isEmpty { save() }
    }

    private func check(index: Int) async {
        guard services.indices.contains(index) else { return }
        let url = services[index].url
        let start = Date()
        var ok = false
        var ms = 0
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            var req = URLRequest(url: parsed)
            req.timeoutInterval = 10
            req.httpMethod = "HEAD"
            req.setValue("CandyIA/1.0", forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await URLSession.shared.data(for: req) {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                ok = code > 0 && code < 500
            } else {
                req.httpMethod = "GET"
                req.timeoutInterval = 10
                if let (_, resp) = try? await URLSession.shared.data(for: req) {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    ok = code > 0 && code < 500
                }
            }
            ms = Int(Date().timeIntervalSince(start) * 1000)
        }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        services[index].checks.append(ServiceCheck(at: Date(), ok: ok, ms: ms))
        services[index].checks.removeAll { $0.at < weekAgo }
        if services[index].checks.count > Self.maxChecks {
            services[index].checks.removeFirst(services[index].checks.count - Self.maxChecks)
        }
        objectWillChange.send()
    }

    func uptime(_ service: MonitoredService, days: Int = 7) -> Double {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let recent = service.checks.filter { $0.at >= cutoff }
        guard !recent.isEmpty else { return 0 }
        let up = recent.filter(\.ok).count
        return Double(up) / Double(recent.count) * 100
    }

    func lastCheck(_ service: MonitoredService) -> ServiceCheck? {
        service.checks.last
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let list = try? JSONDecoder().decode([MonitoredService].self, from: data)
        else {
            if let legacy = try? Data(contentsOf: legacyStoreURL),
               let list = try? JSONDecoder().decode([MonitoredService].self, from: legacy) {
                services = list
                save()
            }
            return
        }
        services = list
    }

    private var legacyStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgenteIAMac", isDirectory: true)
        return dir.appendingPathComponent("services.json")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(services) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}

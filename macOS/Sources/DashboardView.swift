import SwiftUI

struct DashboardView: View {
    @ObservedObject var agent: AgentState
    @ObservedObject var stats = SystemStats.shared
    @ObservedObject var monitor = ServicesMonitor.shared

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                computerCard
                servicesCard
            }
            .padding(20)
        }
        .background(Theme.bg)
    }

    // ------------------------------------------------------------- computer

    private var computerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(Theme.green).frame(width: 8, height: 8)
                Text("Computer")
                    .font(.system(size: 15, weight: .semibold))
                Text("CPU")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(stats.cpuPercent.rounded()))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("%")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                Text(stats.topProcess)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            statRow(label: "Memory",
                    value: "\(Int(stats.memPercent.rounded()))%",
                    color: stats.memPercent > 80 ? Theme.red : (stats.memPercent > 65 ? Theme.amber : Theme.green),
                    detail: String(format: "%.1f / %.1f GB", stats.memUsedGB, stats.memTotalGB))

            if let batt = stats.batteryPercent {
                statRow(label: "Battery",
                        value: "\(batt)%",
                        color: batt > 40 ? Theme.green : (batt > 20 ? Theme.amber : Theme.red),
                        detail: stats.batteryCharging ? "cargando" : "en uso")
            }

            statRow(label: "Modelo",
                    value: agent.ready ? "listo" : "…",
                    color: agent.ready ? Theme.green : Theme.amber,
                    detail: agent.model)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func statRow(label: String, value: String, color: Color, detail: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 15, weight: .bold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // ------------------------------------------------------------- servicios

    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.green)
                Text("Services")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                let upCount = monitor.services.filter {
                    monitor.lastCheck($0)?.ok == true
                }.count
                Text("\(upCount) of \(monitor.services.count) up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        upCount == monitor.services.count ? Theme.green : Theme.amber
                    )
            }

            if monitor.services.isEmpty {
                VStack(spacing: 6) {
                    Text("Sin servicios vigilados")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Pídele a Candy: «vigila https://mi-api.com/health»")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(monitor.services) { svc in
                    serviceRow(svc)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func serviceRow(_ svc: MonitoredService) -> some View {
        let check = monitor.lastCheck(svc)
        let isUp = check?.ok == true
        let uptime = monitor.uptime(svc)
        let bars = Array(svc.checks.suffix(14))

        return HStack(spacing: 10) {
            Circle()
                .fill(isUp ? Theme.green : Theme.red)
                .frame(width: 8, height: 8)
            Text(svc.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(c.ok ? Theme.green : Theme.red)
                        .frame(width: 3, height: 14)
                }
            }
            .frame(height: 14)
            Text("\(Int(uptime.rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(uptime >= 95 ? Theme.green : (uptime >= 80 ? Theme.amber : Theme.red))
                .frame(width: 44, alignment: .trailing)
        }
    }
}

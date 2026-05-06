import SwiftUI
import TimSharedKit

/// Compact persistent banner showing the count of active autonomous
/// tasks plus a status pill. Mounted at the top of TerminalView so it
/// is always visible when the user has a connection.
///
/// Rules:
///   - hidden entirely when activeCount == 0 AND pill == .green
///     (avoids burning vertical space when nothing is running)
///   - tap opens a sheet with the active task list
struct AutonomousBanner: View {
    @ObservedObject var monitor: AutonomousMonitor
    @State private var showSheet = false

    var body: some View {
        if monitor.activeCount == 0 && monitor.pill == .green {
            EmptyView()
        } else {
            Button {
                showSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(pillColour)
                    Text("\(monitor.activeCount) autonomous")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    pillView
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppTheme.cardBackground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(monitor.activeCount) active autonomous tasks. Status \(pillLabel).")
            .sheet(isPresented: $showSheet) {
                AutonomousBannerSheet(monitor: monitor)
            }
        }
    }

    private var pillColour: Color {
        switch monitor.pill {
        case .green: return .green
        case .blue:  return .blue
        case .red:   return .red
        }
    }

    private var pillLabel: String {
        switch monitor.pill {
        case .green: return "idle"
        case .blue:  return "running"
        case .red:   return "alert"
        }
    }

    private var pillView: some View {
        Text(pillLabel)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(pillColour)
            .clipShape(Capsule())
    }
}

private struct AutonomousBannerSheet: View {
    @ObservedObject var monitor: AutonomousMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let err = monitor.lastError {
                    Section("Error") {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
                Section("Active (\(monitor.activeTasks.count))") {
                    if monitor.activeTasks.isEmpty {
                        Text("No active autonomous tasks")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(monitor.activeTasks) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.task.isEmpty ? t.id : t.task)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(formatElapsed(t.elapsedSec))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    if let pid = t.pid {
                                        Text("pid \(pid)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Autonomous tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable {
                monitor.pollNow()
            }
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

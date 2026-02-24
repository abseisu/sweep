// MenuBarView.swift
// The dropdown view when clicking the menu bar icon.
// Two states only: connected (stats + disconnect) or not connected (setup).

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var relayState: RelayState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)
                Text("Sweep Relay")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(relayState.isPaired ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(relayState.isPaired ? "Connected" : "Not connected")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if relayState.isPaired {
                // ── Connected state ──
                VStack(alignment: .leading, spacing: 8) {
                    if let lastSync = relayState.lastSyncTime {
                        statRow(icon: "clock", label: "Last sync", value: timeAgo(lastSync))
                    }
                    statRow(icon: "bubble.left", label: "Messages synced", value: "\(relayState.messagesSynced)")
                    statRow(icon: "arrow.turn.up.right", label: "Replies sent", value: "\(relayState.repliesSent)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                if !relayState.hasFullDiskAccess {
                    Button {
                        relayState.openFullDiskAccessSettings()
                    } label: {
                        Label("Grant Full Disk Access", systemImage: "lock.open")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                Button(role: .destructive) {
                    relayState.unpair()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            } else {
                // ── Not connected state ──
                VStack(spacing: 8) {
                    Text("Not connected to Sweep")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Button("Set Up") {
                        // Open setup window and bring app to front
                        openWindow(id: "setup")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            NSApp.setActivationPolicy(.regular)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(16)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Sweep Relay", systemImage: "power")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}


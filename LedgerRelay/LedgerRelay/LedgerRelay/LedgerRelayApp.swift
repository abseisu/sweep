// LedgerRelayApp.swift
// Sweep Relay — macOS menu bar companion for iMessage integration.

import SwiftUI
import Combine
import ServiceManagement

/// Shared flag so AppDelegate can signal the SwiftUI scene
class LaunchState: ObservableObject {
    static let shared = LaunchState()
    @Published var needsSetup = false
}

@main
struct LedgerRelayApp: App {
    @StateObject private var relayState = RelayState()
    @StateObject private var launchState = LaunchState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu bar icon — always present
        MenuBarExtra {
            MenuBarView()
                .environmentObject(relayState)
        } label: {
            Image(systemName: relayState.isPaired ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        // Setup window
        Window("Sweep Relay", id: "setup") {
            SetupFlowView()
                .environmentObject(relayState)
                .frame(width: 520, height: 620)
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Invisible settings scene that watches for first-launch trigger
        Settings {
            EmptyView()
                .onChange(of: launchState.needsSetup) { _, needs in
                    if needs {
                        openWindow(id: "setup")
                        launchState.needsSetup = false
                    }
                }
                .onChange(of: relayState.isPaired) { _, paired in
                    if !paired && !UserDefaults.standard.bool(forKey: "relay_setup_completed") {
                        openWindow(id: "setup")
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
    }

    private func closeSetupWindow() {
        for window in NSApp.windows where window.title == "Sweep Relay" {
            window.close()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "relay_setup_completed")

        if hasCompletedSetup {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for window in NSApp.windows where window.title == "Sweep Relay" {
                    window.close()
                }
            }
        } else {
            // First launch — trigger setup window
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                LaunchState.shared.needsSetup = true
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

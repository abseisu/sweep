// SetupFlowView.swift
// Step-by-step guided setup for pairing the Mac app with the iOS Sweep account.

import SwiftUI

struct SetupFlowView: View {
    @EnvironmentObject var relayState: RelayState
    @Environment(\.dismiss) private var dismiss
    @State private var step: SetupStep = .welcome

    enum SetupStep: Int, CaseIterable {
        case welcome = 0
        case enterCode = 1
        case fullDiskAccess = 2
        case automationAccess = 3
        case done = 4
    }

    @State private var automationGranted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(SetupStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // Step content
            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .enterCode:
                    enterCodeStep
                case .fullDiskAccess:
                    fullDiskAccessStep
                case .automationAccess:
                    automationAccessStep
                case .done:
                    doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !relayState.isPaired {
                // Always start fresh when not paired (e.g. after disconnect)
                step = .welcome
                automationGranted = false
                automationDenied = false
                code = ""
            } else if relayState.isPaired && !relayState.hasFullDiskAccess {
                step = .fullDiskAccess
            } else if relayState.isPaired && relayState.hasFullDiskAccess {
                step = .automationAccess
            }
        }
        .onChange(of: relayState.isPaired) { _, isPaired in
            if !isPaired {
                // Disconnected — reset to welcome
                step = .welcome
                automationGranted = false
                automationDenied = false
                code = ""
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .thin))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("Sweep Relay")
                    .font(.system(size: 24, weight: .semibold))
                Text("Connect your iMessages to Sweep")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "lock.shield", text: "Your messages stay on your Mac — only new incoming messages are sent to your Sweep account for scoring")
                featureRow(icon: "bolt", text: "Runs silently in the background — launches automatically when you start your Mac")
                featureRow(icon: "arrow.turn.up.right", text: "Reply to iMessages directly from the Sweep app on your iPhone")
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.3)) { step = .enterCode }
            } label: {
                Text("Get Started")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Enter Pairing Code

    @State private var code: String = ""
    @FocusState private var codeFocused: Bool

    private var enterCodeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("Enter Your Pairing Code")
                    .font(.system(size: 20, weight: .semibold))
                Text("Open Sweep on your iPhone, go to\nSettings → Connect iMessage, and enter the code shown.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Code input
            TextField("e.g. A7X4K2", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 200)
                .focused($codeFocused)
                .onSubmit { Task { await pair() } }
                .onChange(of: code) { _, newValue in
                    // Auto-uppercase and limit to 6 chars
                    code = String(newValue.uppercased().prefix(6))
                }

            if let error = relayState.pairingError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            Spacer()

            HStack {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.3)) { step = .welcome }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button {
                    Task { await pair() }
                } label: {
                    if relayState.isPairing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 80)
                    } else {
                        Text("Connect")
                            .frame(width: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.count < 4 || relayState.isPairing)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .onAppear { codeFocused = true }
    }

    private func pair() async {
        await relayState.pair(code: code)
        if relayState.isPaired {
            withAnimation(.easeInOut(duration: 0.3)) {
                if !relayState.hasFullDiskAccess {
                    step = .fullDiskAccess
                } else {
                    step = .automationAccess
                }
            }
        }
    }

    // MARK: - Step 3: Full Disk Access

    private var fullDiskAccessStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.open.laptopcomputer")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("One More Thing")
                    .font(.system(size: 20, weight: .semibold))
                Text("Sweep Relay needs Full Disk Access to read your iMessages.\nYour messages are only used for reply scoring — nothing else.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Step-by-step instructions
            VStack(alignment: .leading, spacing: 14) {
                instructionRow(number: 1, text: "Click the button below to open System Settings")
                instructionRow(number: 2, text: "Find **Sweep Relay** in the list")
                instructionRow(number: 3, text: "Toggle it **on**")
                instructionRow(number: 4, text: "If prompted, click **Quit & Reopen**")
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 8)

            Button {
                relayState.openFullDiskAccessSettings()
            } label: {
                Label("Open System Settings", systemImage: "gear")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 60)

            Spacer()

            HStack {
                Spacer()

                VStack(spacing: 8) {
                    Button {
                        relayState.refreshFullDiskAccess()
                        if relayState.hasFullDiskAccess {
                            withAnimation(.easeInOut(duration: 0.3)) { step = .automationAccess }
                        }
                    } label: {
                        Text(relayState.hasFullDiskAccess ? "Continue" : "I've done this — check again")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderedProminent)

                    if !relayState.hasFullDiskAccess {
                        Text("If you just toggled it on, macOS may require a restart.\nYou can skip for now and it will work after relaunch.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)

                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { step = .automationAccess }
                        } label: {
                            Text("Skip for now")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 4: Automation Access (Messages)

    @State private var automationCheckInProgress = false
    @State private var automationDenied = false

    private var automationAccessStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "message.badge.waveform")
                .font(.system(size: 44, weight: .thin))
                .foregroundColor(.blue)

            VStack(spacing: 8) {
                Text("Allow Messages Access")
                    .font(.system(size: 20, weight: .semibold))
                Text("Sweep Relay needs permission to send iMessages\non your behalf when you reply from your iPhone.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !automationGranted && !automationDenied {
                VStack(alignment: .leading, spacing: 14) {
                    instructionRow(number: 1, text: "Click **Grant Permission** below")
                    instructionRow(number: 2, text: "macOS will ask to control **Messages** — click **OK**")
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
            }

            if automationDenied {
                VStack(spacing: 12) {
                    Text("Permission was denied or the prompt didn't appear.")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 14) {
                        instructionRow(number: 1, text: "Open **System Settings → Privacy & Security → Automation**")
                        instructionRow(number: 2, text: "Find **Sweep Relay** (or **LedgerRelay**) in the list")
                        instructionRow(number: 3, text: "Toggle **Messages** on")
                    }
                    .padding(.horizontal, 40)

                    Button {
                        // Open Automation settings directly
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open Automation Settings", systemImage: "gear")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .padding(.horizontal, 60)
                }
            }

            Button {
                Task { await requestAutomationPermission() }
            } label: {
                if automationCheckInProgress {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    Label(
                        automationGranted ? "Permission Granted ✓" : (automationDenied ? "Check Again" : "Grant Permission"),
                        systemImage: automationGranted ? "checkmark.circle" : "hand.raised"
                    )
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(automationGranted ? .green : .blue)
            .padding(.horizontal, 60)
            .disabled(automationCheckInProgress)

            if automationGranted {
                Text("Messages access confirmed!")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            }

            Spacer()

            HStack {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.3)) { step = .fullDiskAccess }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { step = .done }
                } label: {
                    Text("Continue")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!automationGranted)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .onAppear {
            // Check if already granted (e.g. user going back then forward)
            Task { await checkAutomationSilently() }
        }
    }

    /// Request Automation permission by running osascript as a subprocess.
    /// This is MORE reliable than NSAppleScript for triggering the TCC prompt because
    /// macOS treats subprocess AppleEvents differently and is more likely to prompt.
    private func requestAutomationPermission() async {
        automationCheckInProgress = true
        automationDenied = false

        // Step 1: Use osascript subprocess to trigger TCC prompt.
        // We use "activate" + "count of conversations" which requires actual control of Messages.
        // This forces macOS to ask for permission.
        let granted = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // First, try the most aggressive approach: actually tell Messages to do something
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", """
                    tell application "Messages"
                        activate
                        count of conversations
                    end tell
                    """]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let exitCode = process.terminationStatus
                    print("🔧 osascript exit code: \(exitCode)")
                    // Exit code 0 = success = permission granted
                    // Exit code 1 = error (permission denied or not yet granted)
                    continuation.resume(returning: exitCode == 0)
                } catch {
                    print("❌ Failed to run osascript: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }

        if granted {
            withAnimation { automationGranted = true }
            automationCheckInProgress = false
            // Also store this in RelayState for runtime use
            relayState.hasAutomationAccess = true
            return
        }

        // Step 2: If osascript failed, try NSAppleScript as fallback
        // (sometimes one works when the other doesn't)
        let nsGranted = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = NSAppleScript(source: """
                    tell application "Messages"
                        activate
                        count of conversations
                    end tell
                    """)
                var error: NSDictionary?
                script?.executeAndReturnError(&error)
                if error == nil {
                    continuation.resume(returning: true)
                } else {
                    let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
                    print("⚠️ NSAppleScript error: \(code) — \(error?[NSAppleScript.errorMessage] as? String ?? "")")
                    // -600 = Messages not running but permission may be granted
                    continuation.resume(returning: code == -600)
                }
            }
        }

        automationCheckInProgress = false

        if nsGranted {
            withAnimation { automationGranted = true }
            relayState.hasAutomationAccess = true
        } else {
            withAnimation { automationDenied = true }
        }
    }

    /// Silent check — just verify if we already have permission without triggering a prompt
    private func checkAutomationSilently() async {
        let granted = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Use a read-only query — if it succeeds, permission is granted
                let script = NSAppleScript(source: """
                    tell application "System Events"
                        get name of application process "Messages"
                    end tell
                    """)
                var error: NSDictionary?
                script?.executeAndReturnError(&error)
                if error == nil {
                    continuation.resume(returning: true)
                } else {
                    // Also try the direct approach
                    let script2 = NSAppleScript(source: """
                        tell application "Messages"
                            get name
                        end tell
                        """)
                    var error2: NSDictionary?
                    script2?.executeAndReturnError(&error2)
                    let code = error2?[NSAppleScript.errorNumber] as? Int ?? -1
                    // -600 = not running but permission may be granted, 0 = success
                    continuation.resume(returning: error2 == nil || code == -600)
                }
            }
        }
        if granted {
            withAnimation { automationGranted = true }
            relayState.hasAutomationAccess = true
        }
    }

    // MARK: - Step 5: Done

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.green)
            }

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.system(size: 22, weight: .semibold))
                Text("Sweep Relay is running in your menu bar.\nYour iMessages will now appear in Sweep on your iPhone.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                tipRow(icon: "menubar.rectangle", text: "Click the bubble icon in your menu bar to see status")
                tipRow(icon: "power", text: "Relay launches automatically when your Mac starts")
                tipRow(icon: "moon", text: "It runs silently — you can forget about it")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                NSApp.setActivationPolicy(.accessory)
                dismiss()
            } label: {
                Text("Close Setup")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 60)
            .padding(.bottom, 32)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}


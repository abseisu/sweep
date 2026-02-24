// iMessageSetupView.swift
// Sweep
//
// Guided setup flow for connecting iMessage via the Mac companion app.
// Presented from Settings when the user taps "Connect iMessage".

import SwiftUI

struct iMessageSetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .intro
    @State private var pairingCode: String?
    @State private var isGeneratingCode = false
    @State private var isCheckingStatus = false
    @State private var isConnected = false
    @State private var macName: String?
    @State private var pollTimer: Timer?
    @State private var codeExpiresAt: Date?

    enum Step {
        case intro
        case download
        case pairing
        case connected
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IL.paper.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        switch step {
                        case .intro:     introStep
                        case .download:  downloadStep
                        case .pairing:   pairingStep
                        case .connected: connectedStep
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Connect iMessage")
                        .font(IL.serif(16)).italic()
                        .foregroundColor(IL.paperInkLight)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { cleanup(); dismiss() } label: {
                        Text("Cancel").font(IL.serif(15)).foregroundColor(IL.paperInkLight)
                    }
                }
            }
        }
        .onDisappear { cleanup() }
    }

    // MARK: - Step 1: Intro

    private var introStep: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 20)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundColor(IL.imessageGreen)

            VStack(spacing: 10) {
                Text("iMessage in Sweep")
                    .font(IL.serif(24, weight: .medium))
                    .foregroundColor(IL.paperInk)

                Text("Sweep can score and draft replies for your iMessages — just like it does for email.")
                    .font(IL.serif(14))
                    .foregroundColor(IL.paperInkLight)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            VStack(alignment: .leading, spacing: 16) {
                explanationRow(
                    icon: "laptopcomputer",
                    title: "Requires a Mac",
                    body: "A small companion app runs in your Mac's menu bar and reads your iMessages."
                )
                explanationRow(
                    icon: "lock.shield",
                    title: "Private & secure",
                    body: "Messages are scored by AI and deleted — they're never stored permanently on our servers."
                )
                explanationRow(
                    icon: "bolt",
                    title: "Runs in the background",
                    body: "Once set up, it works automatically whenever your Mac is on. Nothing to think about."
                )
            }
            .padding(.top, 4)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { step = .download }
                } label: {
                    Text("Set Up iMessage")
                        .font(IL.serif(15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(IL.imessageGreen)
                        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                }

                Text("Takes about 2 minutes")
                    .font(IL.serif(11)).italic()
                    .foregroundColor(IL.paperInkFaint)
            }
        }
    }

    // MARK: - Step 2: Download

    private var downloadStep: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 20)

            // Step indicator
            HStack(spacing: 6) {
                stepDot(active: true)
                stepLine()
                stepDot(active: false)
                stepLine()
                stepDot(active: false)
            }

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(IL.accent)

            VStack(spacing: 10) {
                Text("Download Sweep Relay")
                    .font(IL.serif(20, weight: .medium))
                    .foregroundColor(IL.paperInk)

                Text("On your Mac, open this link to download the companion app:")
                    .font(IL.serif(14))
                    .foregroundColor(IL.paperInkLight)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            // URL display
            VStack(spacing: 8) {
                Text("sweepinbox.com/mac")
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundColor(IL.accent)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 24)
                    .background(IL.paperInk.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))

                Button {
                    UIPasteboard.general.string = "https://sweepinbox.com/mac"
                } label: {
                    Label("Copy link", systemImage: "doc.on.doc")
                        .font(IL.serif(12))
                        .foregroundColor(IL.accent)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                instructionRow(number: "1", text: "Open the link on your Mac")
                instructionRow(number: "2", text: "Download and open **Sweep Relay**")
                instructionRow(number: "3", text: "If macOS warns about an unidentified developer, go to System Settings → Privacy & Security and click **Open Anyway**")
            }
            .padding(.top, 4)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.3)) { step = .pairing }
                Task { await generatePairingCode() }
            } label: {
                Text("I've installed it — next")
                    .font(IL.serif(15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(IL.accent)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            }
        }
    }

    // MARK: - Step 3: Pairing

    private var pairingStep: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 20)

            HStack(spacing: 6) {
                stepDot(active: true)
                stepLine()
                stepDot(active: true)
                stepLine()
                stepDot(active: false)
            }

            Image(systemName: "link.badge.plus")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(IL.accent)

            VStack(spacing: 10) {
                Text("Enter This Code on Your Mac")
                    .font(IL.serif(20, weight: .medium))
                    .foregroundColor(IL.paperInk)

                Text("Open Sweep Relay on your Mac and enter this pairing code:")
                    .font(IL.serif(14))
                    .foregroundColor(IL.paperInkLight)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            // Pairing code display
            if let code = pairingCode {
                VStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(IL.ink)
                        .tracking(8)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 32)
                        .background(IL.card)
                        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                        .overlay(
                            RoundedRectangle(cornerRadius: IL.radius)
                                .stroke(IL.accent.opacity(0.3), lineWidth: 1)
                        )

                    if let expires = codeExpiresAt {
                        Text("Expires \(expires, style: .relative)")
                            .font(IL.serif(11)).italic()
                            .foregroundColor(IL.paperInkFaint)
                    }
                }
            } else if isGeneratingCode {
                ProgressView()
                    .padding(.vertical, 20)
            }

            if let error = pairingError {
                Text(error)
                    .font(IL.serif(13))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            if isCheckingStatus {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Waiting for your Mac to connect...")
                        .font(IL.serif(13)).italic()
                        .foregroundColor(IL.paperInkLight)
                }
                .padding(.top, 8)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task { await generatePairingCode() }
                } label: {
                    Text("Generate new code")
                        .font(IL.serif(12)).italic()
                        .foregroundColor(IL.accent)
                }

                Button("Back") {
                    cleanup()
                    withAnimation(.easeInOut(duration: 0.3)) { step = .download }
                }
                .font(IL.serif(13))
                .foregroundColor(IL.paperInkFaint)
            }
        }
    }

    // MARK: - Step 4: Connected

    private var connectedStep: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 20)

            HStack(spacing: 6) {
                stepDot(active: true)
                stepLine()
                stepDot(active: true)
                stepLine()
                stepDot(active: true)
            }

            ZStack {
                Circle()
                    .fill(IL.imessageGreen.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(IL.imessageGreen)
            }

            VStack(spacing: 10) {
                Text("iMessage Connected")
                    .font(IL.serif(22, weight: .medium))
                    .foregroundColor(IL.paperInk)

                if let name = macName {
                    Text("via \(name)")
                        .font(IL.serif(14)).italic()
                        .foregroundColor(IL.paperInkLight)
                }

                Text("Your iMessages will now appear in your Sweep alongside your emails. Make sure your Mac stays on for continuous syncing.")
                    .font(IL.serif(14))
                    .foregroundColor(IL.paperInkLight)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 4)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(IL.serif(15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(IL.imessageGreen)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            }
        }
    }

    // MARK: - Helpers

    private func explanationRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .light))
                .foregroundColor(IL.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IL.serif(14, weight: .medium))
                    .foregroundColor(IL.paperInk)
                Text(body)
                    .font(IL.serif(12))
                    .foregroundColor(IL.paperInkLight)
                    .lineSpacing(3)
            }
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(IL.accent.opacity(0.12))
                    .frame(width: 24, height: 24)
                Text(number)
                    .font(IL.serif(12, weight: .medium))
                    .foregroundColor(IL.accent)
            }
            Text(LocalizedStringKey(text))
                .font(IL.serif(13))
                .foregroundColor(IL.paperInk)
                .lineSpacing(3)
        }
    }

    private func stepDot(active: Bool) -> some View {
        Circle()
            .fill(active ? IL.accent : IL.inkFaint.opacity(0.3))
            .frame(width: 8, height: 8)
    }

    private func stepLine() -> some View {
        Rectangle()
            .fill(IL.paperRule)
            .frame(width: 30, height: 1)
    }

    @State private var pairingError: String?

    // MARK: - API

    private func generatePairingCode() async {
        isGeneratingCode = true
        pairingError = nil
        print("📱 generatePairingCode: starting...")
        do {
            // Ensure we have a backend account (even if no email connected)
            try await BackendManager.shared.ensureRegistered()
            print("📱 generatePairingCode: ensureRegistered succeeded")

            // ALWAYS disconnect any existing relay first.
            // This prevents stale pairings from auto-connecting without a fresh code.
            // If there's no existing pairing, disconnect is a no-op (returns ok: true).
            let _: DisconnectResponse = try await BackendManager.shared.request(
                "POST", path: "/imessage/disconnect"
            )
            print("📱 generatePairingCode: cleared any stale relay pairing")

            let response: PairStartResponse = try await BackendManager.shared.request(
                "POST", path: "/imessage/pair/start"
            )
            print("📱 generatePairingCode: got code \(response.code)")
            pairingCode = response.code
            codeGeneratedAt = Date()
            codeExpiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
            isGeneratingCode = false
            startPolling()
        } catch {
            isGeneratingCode = false
            pairingError = "Could not generate code. Check your connection."
            print("❌ Failed to generate pairing code: \(error)")
        }
    }

    private func startPolling() {
        isCheckingStatus = true
        // Poll every 3 seconds to check if Mac has connected
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                await checkConnection()
            }
        }
    }

    @State private var codeGeneratedAt: Date?

    private func checkConnection() async {
        do {
            let status: iMessageStatus = try await BackendManager.shared.request(
                "GET", path: "/imessage/status"
            )
            if status.connected {
                // Only accept if pairing happened AFTER we generated this code.
                // This prevents stale pairings from auto-connecting.
                var isNewPairing = false

                if let pairedStr = status.pairedAt, let generatedAt = codeGeneratedAt {
                    // Parse ISO 8601 with fractional seconds (backend uses JS toISOString())
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let pairedDate = formatter.date(from: pairedStr) {
                        isNewPairing = pairedDate > generatedAt.addingTimeInterval(-5)
                    } else {
                        // Fallback: try without fractional seconds
                        let fallback = ISO8601DateFormatter()
                        if let pairedDate = fallback.date(from: pairedStr) {
                            isNewPairing = pairedDate > generatedAt.addingTimeInterval(-5)
                        }
                    }
                } else if status.pairedAt == nil {
                    // No pairedAt field — older backend, accept if connected
                    isNewPairing = true
                }

                if isNewPairing {
                    isConnected = true
                    macName = status.macName
                    cleanup()

                    appState.imessageRelayConnected = true
                    appState.imessageRelayMacName = status.macName
                    appState.enableIMessage()

                    withAnimation(.easeInOut(duration: 0.3)) { step = .connected }
                }
                // else: stale pairing from before this code was generated, keep polling
            }
        } catch {
            // Silent — keep polling
        }
    }

    private func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        isCheckingStatus = false
    }
}

// MARK: - Response Types

struct PairStartResponse: Decodable {
    let code: String
    let expiresIn: Int
}

struct DisconnectResponse: Decodable {
    let ok: Bool
}

struct iMessageStatus: Decodable {
    let connected: Bool
    let macName: String?
    let pairedAt: String?
}


// iMessageDraftEditorView.swift
// Ledger
//
// Tap-to-edit flow for iMessage cards.
// User edits the AI-suggested reply, then presses Send
// to open the native Messages compose sheet.

import SwiftUI
import MessageUI

struct iMessageDraftEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let email: LedgerEmail

    @State private var draftText: String = ""
    @State private var showMessageCompose = false
    @State private var originalAIDraft: String = ""
    @State private var aiPrompt: String = ""
    @State private var isRedrafting = false
    @State private var lastRedraftInstruction: String?
    @State private var redraftCount: Int = 0
    @FocusState private var editorFocused: Bool
    @FocusState private var promptFocused: Bool

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IL.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        contextSection
                        rule
                        replySection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20).padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Reply")
                        .font(IL.serif(16)).italic()
                        .foregroundColor(IL.paperInkLight)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Cancel").font(IL.serif(15))
                            .foregroundColor(IL.paperInkLight)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { openMessages() } label: {
                        HStack(spacing: 4) {
                            Text("Send")
                                .font(IL.serif(15, weight: .medium))
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(canSend ? IL.imsgBlue : IL.paperInkFaint)
                    }
                    .disabled(!canSend)
                }
            }
            .onAppear {
                draftText = email.suggestedDraft ?? ""
                if originalAIDraft.isEmpty {
                    originalAIDraft = email.suggestedDraft ?? ""
                }
            }
            .onDisappear {
                let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appState.updateDraft(for: email.id, body: draftText)
                }
            }
            .sheet(isPresented: $showMessageCompose) {
                if MFMessageComposeViewController.canSendText() {
                    MessageComposeView(
                        recipient: email.senderEmail,
                        body: draftText,
                        onDismiss: {
                            showMessageCompose = false
                        },
                        onResult: { result in
                            showMessageCompose = false
                            if result == .sent {
                                // Record style learning — captures whether user edited the draft
                                if SubscriptionManager.shared.styleLearningEnabled {
                                    StyleMemory.shared.recordEdit(
                                        email: email,
                                        aiDraft: originalAIDraft,
                                        userFinal: draftText,
                                        redraftInstruction: lastRedraftInstruction
                                    )
                                }
                                StyleMemory.shared.recordSend()
                                appState.dismiss(item: email)
                                dismiss()
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Context Section

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sender header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [IL.imsgBlue, IL.imsgBlue.opacity(0.8)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Text(String(email.senderName.prefix(1)).uppercased())
                        .font(IL.serif(15, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(email.senderName)
                        .font(IL.serif(16, weight: .medium))
                        .foregroundColor(IL.paperInk)
                    HStack(spacing: 4) {
                        Text("iMessage")
                            .font(IL.serif(11, weight: .medium))
                            .foregroundColor(IL.imsgBlue)
                        Text("·").foregroundColor(IL.paperInkFaint)
                        Text(email.relativeTime)
                            .font(IL.serif(11))
                            .foregroundColor(IL.paperInkFaint)
                    }
                }

                Spacer()
            }

            // AI Summary
            if let summary = email.aiSummary {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(IL.imsgBlue)
                        .frame(width: 20, height: 1.5)
                    Text(summary)
                        .font(IL.serif(14)).italic()
                        .foregroundColor(IL.paperInkLight)
                        .lineSpacing(5)
                }
                .padding(.top, 4)
            }

            // Recent messages (collapsible)
            DisclosureGroup {
                recentMessagesView
                    .padding(.top, 8)
            } label: {
                Text("Recent messages")
                    .font(IL.serif(12)).italic()
                    .foregroundColor(IL.paperInkFaint)
            }
            .tint(IL.paperInkFaint)
        }
    }

    private var recentMessagesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Conversation context from relay (older history)
            if let raw = email.conversationContext,
               !raw.isEmpty,
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CtxMsg].self, from: data) {
                ForEach(Array(decoded.suffix(5).enumerated()), id: \.offset) { _, msg in
                    HStack(alignment: .top, spacing: 6) {
                        Text(msg.isFromMe ? "You:" : "\(msg.senderName ?? email.senderName):")
                            .font(IL.serif(11, weight: .medium))
                            .foregroundColor(msg.isFromMe ? IL.imsgBlue : IL.paperInkLight)
                            .layoutPriority(1)
                        Text(msg.text)
                            .font(IL.serif(11))
                            .foregroundColor(IL.paperInk.opacity(0.7))
                            .lineLimit(3)
                    }
                }
            }

            // Latest messages from body
            let lines = email.body.components(separatedBy: "\n").filter { !$0.isEmpty }
            if !lines.isEmpty {
                ForEach(Array(lines.suffix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(IL.serif(12))
                        .foregroundColor(IL.paperInk.opacity(0.8))
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - Reply Section

    private var replySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your reply")
                    .font(IL.serif(14)).italic()
                    .foregroundColor(IL.paperInk)
                Spacer()
                if let tone = email.detectedTone {
                    Text(tone.capitalized)
                        .font(IL.serif(11)).italic()
                        .foregroundColor(IL.paperInkLight)
                }
            }

            // Reply text editor
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $draftText)
                    .font(IL.serif(15))
                    .foregroundColor(IL.ink)
                    .modifier(HideScrollBackgroundModifier())
                    .frame(minHeight: 140)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .focused($editorFocused)
                    .autocorrectionDisabled(false)
                    .keyboardType(.default)
                    .tint(IL.imsgBlue)
            }
            .background(IL.card)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .overlay(
                RoundedRectangle(cornerRadius: IL.radius)
                    .stroke(IL.imsgBlue.opacity(0.15), lineWidth: 0.5)
            )

            // AI redraft prompt bar
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(IL.inkFaint)
                        .frame(height: 28)

                    if #available(iOS 16.0, *) {
                        TextField("e.g. Make it shorter, More casual...", text: $aiPrompt, axis: .vertical)
                            .font(IL.serif(13))
                            .foregroundColor(IL.ink)
                            .lineLimit(1...6)
                            .focused($promptFocused)
                            .frame(minHeight: 28)
                    } else {
                        TextField("e.g. Make it shorter, More casual...", text: $aiPrompt)
                            .font(IL.serif(13))
                            .foregroundColor(IL.ink)
                            .focused($promptFocused)
                            .frame(height: 28)
                    }

                    Button { redraftWithAI() } label: {
                        if isRedrafting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(IL.imsgBlue)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty ? IL.inkFaint.opacity(0.4) : IL.imsgBlue)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .disabled(aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty || isRedrafting)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                .overlay(
                    RoundedRectangle(cornerRadius: IL.radius)
                        .stroke(IL.ink.opacity(0.1), lineWidth: 0.5)
                )
            }

            Button {
                draftText = originalAIDraft
            } label: {
                Text("Reset to suggestion")
                    .font(IL.serif(12)).italic()
                    .foregroundColor(IL.paperInkLight)
            }
        }
    }

    private var rule: some View {
        Rectangle().fill(IL.paperRule).frame(height: 0.5).padding(.vertical, 20)
    }

    // MARK: - Actions

    private func openMessages() {
        guard canSend else { return }
        editorFocused = false
        promptFocused = false
        showMessageCompose = true
    }

    private func redraftWithAI() {
        guard !aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isRedrafting = true
        editorFocused = false
        promptFocused = false
        let beforeDraft = draftText
        let instruction = aiPrompt

        Task {
            let newDraft = await appState.aiManager.redraft(
                email: email,
                currentDraft: draftText,
                instruction: instruction,
                signature: "",
                redraftCount: redraftCount
            )
            if let newDraft = newDraft {
                if SubscriptionManager.shared.styleLearningEnabled {
                    StyleMemory.shared.recordRedraft(
                        instruction: instruction,
                        beforeDraft: beforeDraft,
                        afterDraft: newDraft
                    )
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    draftText = newDraft
                }
                lastRedraftInstruction = instruction
                redraftCount += 1
            }
            aiPrompt = ""
            isRedrafting = false
        }
    }

    // MARK: - Helpers

    private struct CtxMsg: Decodable {
        let text: String
        let isFromMe: Bool
        let senderName: String?
    }
}

#if DEBUG
struct iMessageDraftEditorView_Previews: PreviewProvider {
    static var previews: some View {
        iMessageDraftEditorView(email: .preview)
            .environmentObject(AppState())
    }
}
#endif

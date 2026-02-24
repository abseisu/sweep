// DraftEditorView.swift
// Ledger

import SwiftUI

struct DraftEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let email: LedgerEmail
    @State private var draftText: String = ""
    @State private var isSending = false
    @State private var showSent = false
    @State private var useReplyAll: Bool = false
    @State private var aiPrompt: String = ""
    @State private var isRedrafting = false
    @State private var originalAIDraft: String = ""  // What AI suggested (before any edits)
    @State private var lastRedraftInstruction: String?  // Last AI prompt instruction used
    @State private var redraftCount: Int = 0  // Escalates to Claude after 2+ redrafts
    @State private var recipientsExpanded = false
    @FocusState private var editorFocused: Bool
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                IL.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        originalSection

                        // Reply-all toggle (only for multi-recipient emails)
                        if email.source == .gmail && email.isMultiRecipient {
                            replyModeSection
                        }

                        rule
                        replySection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20).padding(.bottom, 40)
                }
                if showSent { sentOverlay }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(useReplyAll ? "Reply All" : "Reply")
                        .font(IL.serif(16)).italic().foregroundColor(IL.paperInkLight)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Cancel").font(IL.serif(15)).foregroundColor(IL.paperInkLight)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { sendReply() } label: {
                        if isSending { ProgressView().tint(IL.accent) }
                        else {
                            Text("Send").font(IL.serif(15, weight: .medium))
                                .foregroundColor(canSend ? IL.accent : IL.paperInkFaint)
                        }
                    }
                    .disabled(!canSend || isSending)
                }
            }
            .onAppear {
                // Load the current draft (may have been edited previously)
                var draft = email.suggestedDraft ?? ""
                if appState.appendLedgerSignature && (email.source == .gmail || email.source == .outlook) && !appState.emailSignature.isEmpty {
                    if !draft.contains(appState.emailSignature) {
                        draft += "\n\n\(appState.emailSignature)"
                    }
                }
                draftText = draft
                // Only remember the original AI suggestion on first open
                // (so "Reset to suggestion" always goes back to the AI version)
                if originalAIDraft.isEmpty {
                    originalAIDraft = draft
                }
                useReplyAll = email.suggestReplyAll
            }
            .onDisappear {
                // Auto-save: write the current draft text back to the model
                // so it persists on the card even if user tapped Cancel
                let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appState.updateDraft(for: email.id, body: draftText)
                }
            }
        }
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Original

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(email.priority.color).frame(width: 6, height: 6)
                Text(email.priority.label).font(IL.serif(11, weight: .medium))
                    .foregroundColor(email.priority.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("From").font(IL.serif(10)).italic().foregroundColor(IL.paperInkFaint)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(email.senderName).font(IL.serif(16, weight: .medium)).foregroundColor(IL.paperInk)
                    Text(email.relativeTime).font(IL.serif(11)).foregroundColor(IL.paperInkFaint)
                }
                Text(email.senderEmail).font(IL.serif(11)).foregroundColor(IL.paperInkFaint)
            }

            // Show recipients if multi-recipient
            if email.isMultiRecipient {
                VStack(alignment: .leading, spacing: 2) {
                    if !email.toRecipients.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Text("To").font(IL.serif(10)).italic().foregroundColor(IL.paperInkFaint)
                                .frame(width: 20, alignment: .leading)
                            Text(email.toRecipients.joined(separator: ", "))
                                .font(IL.serif(11)).foregroundColor(IL.paperInkFaint)
                                .lineLimit(recipientsExpanded ? nil : 1)
                        }
                    }
                    if !email.ccRecipients.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Text("CC").font(IL.serif(10)).italic().foregroundColor(IL.paperInkFaint)
                                .frame(width: 20, alignment: .leading)
                            Text(email.ccRecipients.joined(separator: ", "))
                                .font(IL.serif(11)).foregroundColor(IL.paperInkFaint)
                                .lineLimit(recipientsExpanded ? nil : 1)
                        }
                    }
                    if !recipientsExpanded && (email.toRecipients.count + email.ccRecipients.count > 2) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { recipientsExpanded = true }
                        } label: {
                            Text("Show all \(email.toRecipients.count + email.ccRecipients.count) recipients")
                                .font(IL.serif(10)).italic()
                                .foregroundColor(IL.accent)
                        }
                        .padding(.top, 2)
                    }
                }
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { recipientsExpanded.toggle() }
                }
            }

            if !email.subject.isEmpty {
                Text(email.subject).font(IL.serif(20, weight: .medium))
                    .foregroundColor(IL.paperInk).lineSpacing(2)
            }

            if let summary = email.aiSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(email.priority.color).frame(width: 20, height: 1.5)
                    Text(summary).font(IL.serif(14)).italic()
                        .foregroundColor(IL.paperInkLight).lineSpacing(5)
                }
                .padding(.top, 4)
            }

            // Calendar chip
            if CalendarChip.shouldShow(for: email.body) {
                CalendarChip(emailBody: email.body, emailDate: email.date)
                    .padding(.top, 10)
            }

            DisclosureGroup {
                Text(cleanedEmailBody(email.body)).font(IL.serif(13)).foregroundColor(IL.paperInk.opacity(0.8))
                    .lineSpacing(4).padding(.top, 8)
            } label: {
                Text("Original correspondence").font(IL.serif(12)).italic()
                    .foregroundColor(IL.paperInkFaint)
            }
            .tint(IL.paperInkFaint)
        }
    }

    // MARK: - Reply Mode Toggle

    private var replyModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(IL.paperRule).frame(height: 0.5).padding(.top, 16)

            HStack(spacing: 0) {
                // Reply button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { useReplyAll = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 11, weight: .medium))
                        Text("Reply")
                            .font(IL.serif(13, weight: .medium))
                    }
                    .foregroundColor(useReplyAll ? IL.inkFaint : IL.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(useReplyAll ? Color.clear : IL.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                }

                // Reply All button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { useReplyAll = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left.2")
                            .font(.system(size: 11, weight: .medium))
                        Text("Reply All")
                            .font(IL.serif(13, weight: .medium))
                    }
                    .foregroundColor(useReplyAll ? IL.ink : IL.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(useReplyAll ? IL.accent.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                }
            }
            .padding(3)
            .background(IL.card)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius + 2))
            .overlay(
                RoundedRectangle(cornerRadius: IL.radius + 2)
                    .stroke(IL.rule, lineWidth: 0.5)
            )
            .padding(.top, 4)

            // Show who'll receive
            if useReplyAll {
                let recipients = email.replyAllRecipients(excludingUser: appState.userEmail(for: email))
                let allAddresses = recipients.to + recipients.cc
                Text("Sending to \(allAddresses.count) recipients")
                    .font(IL.serif(11)).italic()
                    .foregroundColor(IL.paperInkLight)
            } else {
                Text("Sending to \(email.senderName) only")
                    .font(IL.serif(11)).italic()
                    .foregroundColor(IL.paperInkLight)
            }

            if email.suggestReplyAll && !useReplyAll {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 10, weight: .medium))
                    Text("AI suggests Reply All — others on this thread may need to see your response.")
                        .font(IL.serif(11)).italic()
                }
                .foregroundColor(LedgerPriority.should.color)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Reply

    private var replySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your reply").font(IL.serif(14)).italic().foregroundColor(IL.paperInk)
                Spacer()
                if let tone = email.detectedTone {
                    Text(tone.capitalized).font(IL.serif(11)).italic().foregroundColor(IL.paperInkLight)
                }
            }

            // Single white card containing draft + signature
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $draftText)
                    .font(IL.serif(15))
                    .foregroundColor(IL.ink)
                    .modifier(HideScrollBackgroundModifier())
                    .frame(minHeight: 180)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .focused($editorFocused)
                    .autocorrectionDisabled(false)
                    .keyboardType(.default)
                    .textContentType(nil)
                    .tint(IL.accent)  // Cursor color

                // Provider email signature — inside the card
                if let provSig = appState.providerSignature(for: email), !provSig.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle().fill(IL.ink.opacity(0.08)).frame(height: 0.5)
                            .padding(.horizontal, 16)

                        Text(provSig)
                            .font(IL.serif(12))
                            .foregroundColor(IL.inkFaint)
                            .lineSpacing(3)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                    }
                } else if !appState.appendLedgerSignature && email.source == .outlook {
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle().fill(IL.ink.opacity(0.08)).frame(height: 0.5)
                            .padding(.horizontal, 16)

                        Text("Your Outlook signature will appear below when sent.")
                            .font(IL.serif(11)).italic()
                            .foregroundColor(IL.inkFaint.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                    }
                } else {
                    Spacer().frame(height: 8)
                }
            }
            .background(IL.card)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .overlay(
                RoundedRectangle(cornerRadius: IL.radius)
                    .stroke(IL.ink.opacity(0.1), lineWidth: 0.5)
            )

            // AI re-draft prompt bar
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(IL.inkFaint)
                        .frame(height: 28)

                    if #available(iOS 16.0, *) {
                        TextField("e.g. Make it more casual, Decline politely...", text: $aiPrompt, axis: .vertical)
                            .font(IL.serif(13))
                            .foregroundColor(IL.ink)
                            .lineLimit(1...6)
                            .focused($promptFocused)
                            .frame(minHeight: 28)
                    } else {
                        TextField("e.g. Make it more casual, Decline politely...", text: $aiPrompt)
                            .font(IL.serif(13))
                            .foregroundColor(IL.ink)
                            .focused($promptFocused)
                            .frame(height: 28)
                    }

                    Button {
                        redraftWithAI()
                    } label: {
                        if isRedrafting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(IL.accent)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty ? IL.inkFaint.opacity(0.4) : IL.accent)
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
                Text("Reset to suggestion").font(IL.serif(12)).italic()
                    .foregroundColor(IL.paperInkLight)
            }
        }
    }

    private var rule: some View {
        Rectangle().fill(IL.paperRule).frame(height: 0.5).padding(.vertical, 20)
    }

    // MARK: - AI Redraft

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
                signature: appState.appendLedgerSignature ? appState.emailSignature : "",
                redraftCount: redraftCount
            )
            if let newDraft = newDraft {
                // Record what this instruction produced — teaches future redrafts (paid tiers only)
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

    // MARK: - Send

    private func sendReply() {
        guard canSend, !isSending else { return }
        isSending = true; editorFocused = false

        // Record style learning BEFORE queuing (so it's captured even if undo happens)
        if SubscriptionManager.shared.styleLearningEnabled {
            StyleMemory.shared.recordEdit(
                email: email,
                aiDraft: originalAIDraft,
                userFinal: draftText,
                redraftInstruction: lastRedraftInstruction
            )
        }
        StyleMemory.shared.recordSend()

        // Queue the send with undo window (actual send happens after 10s)
        appState.queueSend(for: email, body: draftText, replyAll: useReplyAll)

        isSending = false
        withAnimation(.easeOut(duration: 0.2)) { showSent = true }

        // Brief "Sent" flash, then dismiss back to card stack (undo toast shows there)
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        }
    }

    private var sentOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("✓").font(IL.serif(32, weight: .light)).foregroundColor(IL.success)
                Text(useReplyAll ? "Sent to all" : "Sent")
                    .font(IL.serif(16)).italic().foregroundColor(IL.ink)
            }
            .padding(40).background(IL.card)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .shadow(color: Color.black.opacity(0.15), radius: 20, y: 8)
        }
        .transition(.opacity)
    }
}

#if DEBUG
struct DraftEditorView_Previews: PreviewProvider {
    static var previews: some View {
        DraftEditorView(email: .preview).environmentObject(AppState())
    }
}
#endif

// MARK: - Email Body Cleaner

/// Strips HTML tags, cleans up URLs, collapses whitespace, and removes
/// common email footer clutter for a readable plain-text display.
private func cleanedEmailBody(_ raw: String) -> String {
    var text = raw

    // 1. Strip HTML tags
    text = text.replacingOccurrences(
        of: "<[^>]+>",
        with: "",
        options: .regularExpression
    )

    // 2. Decode common HTML entities
    let entities: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&nbsp;", " "), ("&#160;", " "), ("&ndash;", "–"),
        ("&mdash;", "—"), ("&rsquo;", "'"), ("&lsquo;", "'"),
        ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ("&bull;", "•"), ("&hellip;", "…"), ("&#8203;", ""),
        ("&zwnj;", ""), ("&zwj;", "")
    ]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }

    // 3. Shorten long URLs — replace full URLs with [link] or domain
    text = text.replacingOccurrences(
        of: "https?://[^\\s)\\]>]{60,}",
        with: "[link]",
        options: .regularExpression
    )

    // 4. Collapse multiple blank lines into max 2
    text = text.replacingOccurrences(
        of: "\\n{3,}",
        with: "\n\n",
        options: .regularExpression
    )

    // 5. Collapse multiple spaces
    text = text.replacingOccurrences(
        of: " {2,}",
        with: " ",
        options: .regularExpression
    )

    // 6. Trim leading/trailing whitespace per line
    text = text
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")

    // 7. Remove zero-width characters
    text = text.replacingOccurrences(of: "\u{200B}", with: "")
    text = text.replacingOccurrences(of: "\u{200C}", with: "")
    text = text.replacingOccurrences(of: "\u{200D}", with: "")
    text = text.replacingOccurrences(of: "\u{FEFF}", with: "")

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}


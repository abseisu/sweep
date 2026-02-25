// AIManager.swift
// Ledger
//
// AI manager that routes all scoring and redraft calls through the Ledger backend.
// No API keys stored in the app — the backend handles provider selection and billing.

import Foundation

final class AIManager {

    // MARK: - Analyze Email (via Backend)

    func analyze(email: LedgerEmail) async throws -> AIResponse {
        let backendEmail = backendEmail(from: email)
        let styleContext = buildStyleContext(for: email)
        let scores = try await BackendManager.shared.scoreEmails([backendEmail], styleContext: styleContext)
        guard let s = scores.first else { throw AIError.emptyResponse }
        return AIResponse(
            summary: s.summary ?? "",
            draftResponse: stripPlaceholders(s.draft ?? ""),
            detectedTone: s.tone ?? "formal",
            replyability: s.replyability,
            category: s.category ?? "work",
            suggestReplyAll: s.suggestReplyAll ?? false
        )
    }

    // MARK: - Batch Analyze (via Backend)

    func analyzeBatch(emails: [LedgerEmail]) async -> [AIResponse?] {
        guard !emails.isEmpty else { return [] }

        let backendEmails = emails.map { backendEmail(from: $0) }
        let styleContext = buildStyleContext(for: emails.first)

        do {
            let scores = try await BackendManager.shared.scoreEmails(backendEmails, styleContext: styleContext)

            // Build a lookup by ID so we match scores to the correct email
            var scoreById: [String: BackendManager.EmailScore] = [:]
            for score in scores {
                scoreById[score.id] = score
            }

            var results: [AIResponse?] = []
            for email in emails {
                if let s = scoreById[email.id] {
                    results.append(AIResponse(
                        summary: s.summary ?? "",
                        draftResponse: stripPlaceholders(s.draft ?? ""),
                        detectedTone: s.tone ?? "formal",
                        replyability: s.replyability,
                        category: s.category ?? "work",
                        suggestReplyAll: s.suggestReplyAll ?? false
                    ))
                } else {
                    // No score for this email — AI may have skipped it
                    print("   ⚠️ No AI score returned for \(email.senderName) (id: \(email.id))")
                    results.append(nil)
                }
            }

            print("✅ Batch scored \(scores.count)/\(emails.count) emails via backend")
            return results
        } catch {
            print("⚠️ Backend batch scoring failed: \(error.localizedDescription)")
            // Fall back to individual calls
            var results: [AIResponse?] = []
            for email in emails {
                results.append(try? await analyze(email: email))
            }
            return results
        }
    }

    // MARK: - Redraft (via Backend)

    func redraft(email: LedgerEmail, currentDraft: String, instruction: String, signature: String, redraftCount: Int = 0) async -> String? {
        let backendEmail = backendEmail(from: email)
        let styleContext = buildStyleContext(for: email)

        do {
            var text = try await BackendManager.shared.redraft(
                email: backendEmail,
                currentDraft: currentDraft,
                instruction: instruction,
                redraftCount: redraftCount,
                styleContext: styleContext
            )

            text = text
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip any placeholder patterns the AI may have generated
            text = stripPlaceholders(text)

            // Append signature for email sources (with duplicate check)
            if (email.source == .gmail || email.source == .outlook) && !signature.isEmpty && !text.contains(signature) {
                text += "\n\n\(signature)"
            }

            return text
        } catch {
            print("❌ Backend redraft error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Convert a LedgerEmail to the BackendManager's EmailForScoring format
    private func backendEmail(from email: LedgerEmail) -> BackendManager.EmailForScoring {
        BackendManager.EmailForScoring(
            id: email.id,
            from: email.senderName,
            fromEmail: email.senderEmail,
            subject: email.subject,
            body: String(email.body.prefix(10000)),
            source: sourceLabel(for: email),
            isUnread: email.isUnread,
            hasReplied: email.userHasReplied,
            attachmentSummary: email.attachmentSummary,
            linkSummary: email.hasLinks
                ? email.detectedLinks.prefix(3).map { "\($0.linkType.label): \($0.displayText)" }.joined(separator: ", ")
                : nil,
            recipients: email.toRecipients.isEmpty ? nil : email.toRecipients.joined(separator: ", ")
        )
    }

    /// Build style context string from StyleMemory, DismissalMemory, and CalendarManager.
    /// This context is sent to the backend AI for both scoring and draft generation.
    private func buildStyleContext(for email: LedgerEmail?) -> String? {
        var sections: [String] = []

        // 1. Learned writing style (from user's actual edits/sends)
        let hasStyleProfile = StyleMemory.shared.stylePromptSection() != nil
        if let styleSection = StyleMemory.shared.stylePromptSection() {
            sections.append(styleSection)
        }
        if let prefsSection = StyleMemory.shared.preferencesPromptSection() {
            sections.append(prefsSection)
        }

        // 2. Etiquette defaults — used BEFORE StyleMemory has enough data.
        //    Provides conventional formatting (greetings for email, casual for iMessage).
        if let email = email,
           let etiquette = DismissalMemory.etiquetteDefaults(for: email.source, hasStyleProfile: hasStyleProfile) {
            sections.append(etiquette)
        }

        // 3. Per-contact style hints
        if let email = email {
            if SubscriptionManager.shared.perContactStyleEnabled,
               let contactHint = StyleMemory.shared.contactStyleHint(for: email) {
                sections.append(contactHint)
            }
            if let calContext = CalendarManager.shared.availabilityContext(for: email.body) {
                sections.append(calContext)
            }
        }

        // 4. Dismissal patterns — tells AI which senders/domains user consistently ignores
        if let dismissalSection = DismissalMemory.shared.scoringPromptSection() {
            sections.append(dismissalSection)
        }

        // 5. Sign-off name + anti-placeholder instructions
        let signOffName = UserDefaults.standard.string(forKey: "ledger_signature") ?? ""
        let appendName = UserDefaults.standard.object(forKey: "ledger_append_signature") as? Bool ?? true

        var signOffSection = "CRITICAL FORMATTING RULES:\n"
        signOffSection += "- NEVER use placeholder text like [Your Name], [Name], [Insert Name], [First Name], or any bracketed placeholder in any draft.\n"
        signOffSection += "- Every draft must be immediately ready to send with zero edits needed.\n"
        if appendName && !signOffName.isEmpty {
            signOffSection += "- The user's sign-off name is \"\(signOffName)\". Always end email drafts with this exact name.\n"
            signOffSection += "- Do not use any other name or variation."
        } else {
            signOffSection += "- The user has NOT configured a sign-off name. Do NOT end drafts with any name or signature line.\n"
            signOffSection += "- Do not guess or infer the user's name. End with the closing phrase only (e.g. \"Best,\" or \"Thanks,\") or no sign-off at all."
        }
        sections.append(signOffSection)

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Strip placeholder patterns like [Your Name], [Name], etc. from AI-generated text.
    /// Safety net in case the AI ignores the anti-placeholder instruction.
    private func stripPlaceholders(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text.replacingOccurrences(
            of: "\\[(?:Your |My |Insert |Full )?(?:Name|Signature|Name Here|First Name)\\]",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Clean up trailing whitespace/newlines left after stripping
        result = result.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sourceLabel(for email: LedgerEmail) -> String {
        switch email.source {
        case .gmail, .outlook: return "Email"
        case .slack: return "Slack"
        case .teams: return "Teams"
        case .telegram: return "Telegram"
        case .imessage: return "iMessage"
        case .groupme: return "GroupMe"
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case apiError(statusCode: Int)
    case emptyResponse
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .apiError(let c): return "API returned status \(c)"
        case .emptyResponse:   return "Empty AI response"
        case .parsingFailed:   return "Failed to parse AI response"
        }
    }
}


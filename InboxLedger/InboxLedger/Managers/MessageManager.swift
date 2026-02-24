// MessageManager.swift
// Ledger
//
// iMessage integration — send-only via the native Messages compose sheet.
// No special entitlements or permissions required.
//
// Apple does not provide a public API to read iMessages,
// so this source works as a quick-reply channel:
// the AI drafts a response and the user sends it via the compose sheet.

import UIKit
import SwiftUI
import MessageUI

final class MessageManager: NSObject {

    // MARK: - Availability

    static var canSendMessages: Bool {
        MFMessageComposeViewController.canSendText()
    }

    // MARK: - Fetch

    /// Fetches iMessages from the backend that were pushed by the Mac relay.
    func fetchRecentMessages() async throws -> [LedgerEmail] {
        struct RelayMessage: Decodable {
            let id: String
            let senderName: String
            let senderPhone: String
            let text: String
            let date: String
            let chatId: String
            let isGroupChat: Bool?
            let groupName: String?
            let isFromMe: Bool?
            let aiSummary: String?
            let suggestedDraft: String?
            let replyability: Int?
            let detectedTone: String?
            let category: String?
            let conversationContext: [RelayContextMessage]?
            let structuredMessages: [StructuredMessage]?
        }
        struct RelayContextMessage: Decodable {
            let text: String
            let isFromMe: Bool
            let date: String
            let senderName: String?
        }
        struct StructuredMessage: Decodable {
            let text: String
            let date: String
            let senderName: String?
        }
        struct MessagesResponse: Decodable {
            let messages: [RelayMessage]
        }

        let response: MessagesResponse = try await BackendManager.shared.request(
            "GET", path: "/imessage/messages"
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        return response.messages.compactMap { msg in
            // Parse date
            let date = formatter.date(from: msg.date)
                ?? fallbackFormatter.date(from: msg.date)
                ?? Date()

            // Build conversation context string for the card's body
            var contextParts: [String] = []
            if let ctx = msg.conversationContext {
                for c in ctx.suffix(20) {
                    let prefix = c.isFromMe ? "→ Me" : "← \(c.senderName ?? msg.senderName)"
                    let cDate = formatter.date(from: c.date)
                        ?? fallbackFormatter.date(from: c.date)
                        ?? date
                    let timeStr = RelativeDateTimeFormatter().localizedString(for: cDate, relativeTo: Date())
                    contextParts.append("[\(timeStr)] \(prefix): \(c.text)")
                }
            }

            // If this message is from me, skip it — we only want incoming messages
            if msg.isFromMe == true { return nil }

            // Serialize conversation context as JSON for the card's scroll history
            var conversationContextJSON: String? = nil
            if let ctx = msg.conversationContext, !ctx.isEmpty {
                let ctxDicts: [[String: Any]] = ctx.map { c in
                    var d: [String: Any] = [
                        "text": c.text,
                        "isFromMe": c.isFromMe,
                    ]
                    if let name = c.senderName { d["senderName"] = name }
                    return d
                }
                if let data = try? JSONSerialization.data(withJSONObject: ctxDicts),
                   let str = String(data: data, encoding: .utf8) {
                    conversationContextJSON = str
                }
            }

            // Build snippet from structured messages as JSON (card view parses this)
            let snippetText: String
            if let structured = msg.structuredMessages, !structured.isEmpty {
                let structDicts: [[String: Any]] = structured.map { m in
                    var d: [String: Any] = [
                        "text": m.text,
                        "date": m.date,
                    ]
                    if let name = m.senderName { d["senderName"] = name }
                    return d
                }
                if let data = try? JSONSerialization.data(withJSONObject: structDicts),
                   let str = String(data: data, encoding: .utf8) {
                    snippetText = str
                } else {
                    snippetText = structured.map { $0.text }.joined(separator: "\n")
                }
            } else {
                snippetText = String(msg.text.prefix(100))
            }

            let body = msg.text

            var item = LedgerEmail(
                id: msg.id,
                source: .imessage,
                threadId: msg.chatId,
                messageId: "",
                senderName: msg.isGroupChat == true ? (msg.groupName ?? msg.senderName) : msg.senderName,
                senderEmail: msg.senderPhone,
                subject: "",
                snippet: snippetText,
                body: body,
                date: date,
                isUnread: true,
                accountId: "imessage",
                aiSummary: msg.aiSummary,
                suggestedDraft: msg.suggestedDraft,
                replyability: msg.replyability ?? 60
            )
            item.detectedTone = msg.detectedTone
            item.category = msg.category
            item.conversationContext = conversationContextJSON
            return item
        }
    }
}

// MARK: - SwiftUI Bridge for Message Compose

struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    var onDismiss: () -> Void

    func makeUIViewController(context: UIViewControllerRepresentableContext<MessageComposeView>) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: UIViewControllerRepresentableContext<MessageComposeView>) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
            onDismiss()
        }
    }
}

// MARK: - Errors

enum MessageError: LocalizedError {
    case cannotSendMessages

    var errorDescription: String? {
        switch self {
        case .cannotSendMessages:
            return "This device cannot send text messages."
        }
    }
}

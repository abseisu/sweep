// LedgerEmail.swift
// Ledger

import Foundation
import SwiftUI

enum LedgerSource: String, Equatable, Codable {
    case gmail
    case outlook
    case teams
    case slack
    case telegram
    case imessage
    case groupme
}

enum LedgerPriority: String, Comparable, Codable {
    case must = "must"       // Must reply tonight
    case should = "should"   // Should reply soon
    case low = "low"         // Can wait or skip

    static func < (lhs: LedgerPriority, rhs: LedgerPriority) -> Bool {
        let order: [LedgerPriority] = [.must, .should, .low]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    var label: String {
        switch self {
        case .must:   return "Reply tonight"
        case .should: return "Worth a reply"
        case .low:    return "Low priority"
        }
    }

    var color: Color {
        switch self {
        case .must:   return Color(red: 0.72, green: 0.20, blue: 0.15)
        case .should: return Color(red: 0.65, green: 0.50, blue: 0.15)
        case .low:    return Color(red: 0.35, green: 0.45, blue: 0.35)
        }
    }
}

struct LedgerEmail: Identifiable, Equatable, Codable {
    let id: String
    let source: LedgerSource
    let threadId: String
    let messageId: String
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let date: Date
    let isUnread: Bool
    var accountId: String = ""      // Which ConnectedAccount this came from

    // Recipients (for reply-all support)
    var toRecipients: [String] = []    // All To: addresses
    var ccRecipients: [String] = []    // All CC: addresses

    // Attachments & links
    var attachments: [EmailAttachment] = []
    var detectedLinks: [DetectedLink] = []

    // AI-generated
    var aiSummary: String?
    var suggestedDraft: String?
    var detectedTone: String?
    var replyability: Int = 0
    var category: String?
    var suggestReplyAll: Bool = false   // AI recommends reply-all
    var userHasReplied: Bool = false     // User already replied to this thread
    var isEarlierThisWeek: Bool = false  // Tagged during first-run: email is from days 2–7 (not last 24h)
    var conversationContext: String?      // JSON array of prior messages for iMessage scroll history

    // Explicit CodingKeys — only stored properties, excludes all computed
    enum CodingKeys: String, CodingKey {
        case id, source, threadId, messageId, senderName, senderEmail
        case subject, snippet, body, date, isUnread, accountId
        case toRecipients, ccRecipients
        case attachments, detectedLinks
        case aiSummary, suggestedDraft, detectedTone, replyability
        case category, suggestReplyAll, userHasReplied, isEarlierThisWeek, conversationContext
    }

    /// Real attachments (not inline images like logos/signatures)
    var realAttachments: [EmailAttachment] {
        attachments.filter { !$0.isInline }
    }

    /// Whether this email has any real (non-inline) attachments
    var hasAttachments: Bool { !realAttachments.isEmpty }

    /// Whether this email has any actionable detected links
    var hasLinks: Bool { !detectedLinks.isEmpty }

    /// Attachment summary for AI context (e.g. "2 attachments: Budget.pdf (1.2 MB), photo.jpg (340 KB)")
    var attachmentSummary: String? {
        guard hasAttachments else { return nil }
        let descs = realAttachments.map { "\($0.filename) (\($0.formattedSize))" }
        return "\(realAttachments.count) attachment\(realAttachments.count == 1 ? "" : "s"): \(descs.joined(separator: ", "))"
    }

    /// True if email was sent to multiple people
    var isMultiRecipient: Bool {
        let total = toRecipients.count + ccRecipients.count
        return total > 1
    }

    /// All recipients except the current user (for reply-all)
    func replyAllRecipients(excludingUser userEmail: String) -> (to: [String], cc: [String]) {
        let user = userEmail.lowercased()
        // Reply-all To: original sender + all To recipients minus self
        var to = [senderEmail]
        to.append(contentsOf: toRecipients.filter { $0.lowercased() != user && $0.lowercased() != senderEmail.lowercased() })
        // CC: same as original CC minus self
        let cc = ccRecipients.filter { $0.lowercased() != user }
        return (to, cc)
    }       // personal, work, transactional, marketing, notification

    // Computed
    var priority: LedgerPriority {
        if replyability >= 70 { return .must }
        if replyability >= 40 { return .should }
        return .low
    }

    var senderInitial: String {
        String(senderName.prefix(1)).uppercased()
    }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var sourceLabel: String {
        switch source {
        case .gmail:    return "Gmail"
        case .outlook:  return "Outlook"
        case .teams:    return "Teams"
        case .slack:    return "Slack"
        case .telegram: return "Telegram"
        case .imessage: return "iMessage"
        case .groupme:  return "GroupMe"
        }
    }

    /// Shows the specific account (e.g. "work@gmail.com") when disambiguating
    var accountLabel: String {
        accountId.isEmpty ? sourceLabel : accountId
    }

    static func == (lhs: LedgerEmail, rhs: LedgerEmail) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Previews

#if DEBUG
extension LedgerEmail {
    static let preview = LedgerEmail(
        id: "msg_001", source: .gmail, threadId: "t1", messageId: "<a@b.com>",
        senderName: "Alex Rivera", senderEmail: "alex@example.com",
        subject: "Q4 Budget Review — Need Your Sign-off",
        snippet: "Hey, just wanted to follow up on the Q4 budget...",
        body: "Hey,\n\nJust wanted to follow up on the Q4 budget numbers we discussed last Thursday. The finance team needs your sign-off by EOD Friday.\n\nI've attached the spreadsheet and shared the doc here: https://docs.google.com/spreadsheets/d/abc123\n\nThanks,\nAlex",
        date: Date().addingTimeInterval(-3600 * 3), isUnread: true,
        toRecipients: ["you@example.com", "finance@example.com"],
        ccRecipients: ["cfo@example.com"],
        attachments: [
            EmailAttachment(id: "att1", filename: "Q4_Budget_2025.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 245_000, isInline: false)
        ],
        detectedLinks: [
            DetectedLink(url: URL(string: "https://docs.google.com/spreadsheets/d/abc123")!, displayText: "Google Sheet", linkType: .document)
        ],
        aiSummary: "Alex needs your approval on Q4 budget by Friday EOD. Attached the spreadsheet and shared a Google Sheet link.",
        suggestedDraft: "Hi Alex,\n\nI'll review the spreadsheet this afternoon and get back to you before the Friday deadline.\n\nBest regards",
        detectedTone: "formal", replyability: 85, category: "work",
        suggestReplyAll: true
    )

    static let previewCasual = LedgerEmail(
        id: "msg_002", source: .imessage, threadId: "t2", messageId: "",
        senderName: "Jamie Chen", senderEmail: "+1 (555) 234-5678",
        subject: "", snippet: "Hey! Free for lunch tomorrow?",
        body: "Hey! Are you free for lunch tomorrow? Thinking that new ramen place on 5th. 12:30?",
        date: Date().addingTimeInterval(-3600), isUnread: true,
        aiSummary: "Jamie wants lunch tomorrow at 12:30, ramen on 5th Street.",
        suggestedDraft: "Sounds great — 12:30 works. See you there!",
        detectedTone: "casual", replyability: 75, category: "personal"
    )

    static let previewUrgent = LedgerEmail(
        id: "msg_003", source: .gmail, threadId: "t3", messageId: "<g@h.com>",
        senderName: "Dana Owens", senderEmail: "dana@example.com",
        subject: "URGENT: Server outage — need help ASAP",
        snippet: "The prod server went down 10 minutes ago.",
        body: "The prod server went down about 10 minutes ago and we're getting 500s across the board. Can you jump on a call ASAP?\n\nZoom: https://zoom.us/j/123456789",
        date: Date().addingTimeInterval(-600), isUnread: true,
        detectedLinks: [
            DetectedLink(url: URL(string: "https://zoom.us/j/123456789")!, displayText: "Zoom", linkType: .meeting)
        ],
        aiSummary: "Production down with 500 errors. Needs you on a call immediately. Zoom link included.",
        suggestedDraft: "On it — jumping into #incident now. 2 minutes.",
        detectedTone: "urgent", replyability: 98, category: "work"
    )

    static let previewLow = LedgerEmail(
        id: "msg_004", source: .gmail, threadId: "t4", messageId: "<r@s.com>",
        senderName: "Spotify", senderEmail: "no-reply@spotify.com",
        subject: "Your weekly playlist is ready",
        snippet: "Check out your Discover Weekly...",
        body: "Your Discover Weekly playlist has been updated with 30 fresh tracks.",
        date: Date().addingTimeInterval(-7200), isUnread: true,
        aiSummary: "Automated playlist notification from Spotify.",
        suggestedDraft: "", detectedTone: "casual", replyability: 2, category: "marketing"
    )

    static let previewList: [LedgerEmail] = [.previewUrgent, .preview, .previewCasual, .previewLow]
}
#endif

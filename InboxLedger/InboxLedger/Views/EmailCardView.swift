// EmailCardView.swift
// Ledger

import SwiftUI

struct EmailCardView: View {
    @EnvironmentObject var appState: AppState
    let email: LedgerEmail
    let isTopCard: Bool
    var maxHeight: CGFloat = .infinity

    @State private var offset: CGFloat = 0
    @State private var verticalOffset: CGFloat = 0
    @State private var showDraftEditor = false
    @State private var showIMessageDraftEditor = false
    @State private var showSnoozed = false
    private let threshold: CGFloat = 120

    /// Show specific account email when user has multiple of same service
    private var cardSourceLabel: String {
        let sameServiceCount = appState.accounts.filter { $0.service.rawValue == email.source.rawValue }.count
        if sameServiceCount > 1 && !email.accountId.isEmpty {
            return email.accountId
        }
        return email.sourceLabel
    }
    private let verticalThreshold: CGFloat = 100

    @State private var offsetY: CGFloat = 0

    private var isIMessage: Bool { email.source == .imessage }

    var body: some View {
        Group {
            if isIMessage {
                iMessageCardBody
                    .frame(maxHeight: maxHeight) // iMessage has ScrollView — needs bounding
            } else {
                emailCardBody // sizes naturally to content — no forced height
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .background(
            RoundedRectangle(cornerRadius: cardRadius)
                .fill(isIMessage ? IL.imsgCard : cardBackground)
                .shadow(color: Color.black.opacity(0.10), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(isIMessage ? IL.imsgRule.opacity(0.5) : cardBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            if isIMessage {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [IL.imsgBlue, IL.imsgBlue.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 3).padding(.vertical, 12)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [sourceColor, sourceColor.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 3).padding(.vertical, 12)
            }
        }
        // Swipe overlays
        .overlay(swipeOverlays)
        .offset(x: offset, y: max(0, offsetY))
        .rotationEffect(.degrees(Double(offset) / 40), anchor: .bottom)
        .gesture(
            isTopCard
            ? DragGesture()
                .onChanged { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    if abs(h) > abs(v) {
                        offset = h
                        offsetY = 0
                    } else if v > 0 {
                        offsetY = v
                        offset = 0
                    }
                }
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    if abs(h) > abs(v) {
                        handleSwipe(h)
                    } else if v > threshold {
                        handleSnooze()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            offset = 0
                            offsetY = 0
                        }
                    }
                }
            : nil
        )
        .onTapGesture {
            if isTopCard {
                if isIMessage { showIMessageDraftEditor = true }
                else { showDraftEditor = true }
            }
        }
        .sheet(isPresented: $showDraftEditor) { DraftEditorView(email: email) }
        .sheet(isPresented: $showIMessageDraftEditor) {
            iMessageDraftEditorView(email: email)
        }
        .sheet(item: $selectedLink) { link in
            SafariView(url: link.url)
                .ignoresSafeArea()
        }
        .allowsHitTesting(isTopCard)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Swipe Overlays
    // ═══════════════════════════════════════════════════════════════════════

    private var swipeOverlays: some View {
        Group {
            if offset < -30 {
                RoundedRectangle(cornerRadius: cardRadius)
                    .fill(IL.accent.opacity(min(Double(-offset) / 250, 0.35)))
                    .overlay(
                        Text("Dismiss").font(IL.serif(16)).italic()
                            .foregroundColor(.white.opacity(0.85))
                    )
            }
            if offset > 30 {
                RoundedRectangle(cornerRadius: cardRadius)
                    .fill((isIMessage ? IL.imsgBlue : IL.success).opacity(min(Double(offset) / 250, 0.35)))
                    .overlay(
                        Text("Send").font(IL.serif(16)).italic()
                            .foregroundColor(.white.opacity(0.85))
                    )
            }
            if offsetY > 30 {
                RoundedRectangle(cornerRadius: cardRadius)
                    .fill(Color(red: 0.25, green: 0.35, blue: 0.55).opacity(min(Double(offsetY) / 250, 0.35)))
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 16, weight: .light))
                            Text(appState.snoozeLabel.capitalized).font(IL.serif(16)).italic()
                        }
                        .foregroundColor(.white.opacity(0.85))
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - iMessage Card Layout
    // Conversational: avatar, scrollable history, chat bubbles, reply bubble
    // ═══════════════════════════════════════════════════════════════════════

    private var iMessageCardBody: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: avatar + name + meta (pinned top) ──
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [IL.imsgBlue, IL.imsgBlue.opacity(0.8)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 38, height: 38)
                    Text(String(email.senderName.prefix(1)).uppercased())
                        .font(IL.serif(16, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(email.senderName)
                        .font(IL.serif(16, weight: .medium))
                        .foregroundColor(IL.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("iMessage")
                            .font(IL.serif(11, weight: .medium))
                            .foregroundColor(IL.imsgBlue)
                        Text("·")
                            .foregroundColor(IL.imsgInkLight)
                        Text(email.priority.label)
                            .font(IL.serif(11))
                            .foregroundColor(IL.imsgInkLight)
                    }
                }

                Spacer()

                Text(email.relativeTime)
                    .font(IL.serif(11))
                    .foregroundColor(IL.imsgInkLight)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // ── Scrollable conversation thread ──
            // Context from relay (older history) + latest burst only
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {

                        // Context messages (older conversation history from relay)
                        if let contextMessages = parsedConversationContext, !contextMessages.isEmpty {
                            Text("↑ Conversation history")
                                .font(IL.serif(9)).italic()
                                .foregroundColor(IL.imsgInkLight)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                                .padding(.bottom, 2)

                            ForEach(Array(contextMessages.enumerated()), id: \.offset) { _, msg in
                                if msg.isFromMe {
                                    HStack {
                                        Spacer(minLength: 60)
                                        Text(msg.text)
                                            .font(IL.serif(13))
                                            .foregroundColor(.white.opacity(0.85))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(IL.imsgBlue.opacity(0.4))
                                            .clipShape(BubbleShape(isOutgoing: true))
                                    }
                                    .padding(.trailing, 18)
                                } else {
                                    HStack {
                                        Text(msg.text)
                                            .font(IL.serif(13))
                                            .foregroundColor(IL.ink.opacity(0.65))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(IL.imsgBubble.opacity(0.5))
                                            .clipShape(BubbleShape(isOutgoing: false))
                                        Spacer(minLength: 60)
                                    }
                                    .padding(.leading, 18)
                                }
                            }

                            // Divider between context and latest messages
                            HStack(spacing: 8) {
                                Rectangle().fill(IL.imsgRule).frame(height: 0.5)
                                Text("New")
                                    .font(IL.serif(9, weight: .medium))
                                    .foregroundColor(IL.imsgBlue)
                                Rectangle().fill(IL.imsgRule).frame(height: 0.5)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                        }

                        // Latest burst only — NOT all messages in the chain
                        let split = splitLatestBurst()
                        let burstMessages = split.latest

                        ForEach(Array(burstMessages.enumerated()), id: \.offset) { idx, msg in
                            // Timestamp separator for gaps > 2 min
                            if idx > 0, let prevDate = burstMessages[idx - 1].date, let thisDate = msg.date {
                                let gap = thisDate.timeIntervalSince(prevDate)
                                if gap > 120 {
                                    Text(relativeTimestamp(thisDate))
                                        .font(IL.serif(9))
                                        .foregroundColor(IL.imsgInkLight)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 2)
                                }
                            }

                            HStack {
                                VStack(alignment: .leading) {
                                    Text(msg.text)
                                        .font(IL.serif(15))
                                        .foregroundColor(IL.ink)
                                        .lineSpacing(4)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(IL.imsgBubble)
                                .clipShape(BubbleShape(isOutgoing: false))

                                Spacer(minLength: 40)
                            }
                            .padding(.leading, 18)
                        }

                        // Anchor for auto-scroll to bottom
                        Color.clear.frame(height: 1).id("conversationBottom")
                    }
                    .padding(.trailing, 18)
                }
                .onAppear {
                    proxy.scrollTo("conversationBottom", anchor: .bottom)
                }
            }

            // ── AI Summary (pinned below scroll) ──
            if let summary = email.aiSummary {
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(IL.imsgBlue)
                        .frame(width: 16, height: 1.5)
                        .padding(.bottom, 6)
                    Text(summary)
                        .font(IL.serif(12)).italic()
                        .foregroundColor(IL.imsgSummaryInk)
                        .lineSpacing(4)
                        .lineLimit(4)
                }
                .padding(.leading, 18)
                .padding(.trailing, 40)
                .padding(.top, 10)
            }

            // ── Reply draft (outgoing — right aligned, blue bubble) ──
            if let draft = email.suggestedDraft, !draft.isEmpty {
                HStack {
                    Spacer(minLength: 60)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Your reply")
                            .font(IL.serif(9)).italic()
                            .foregroundColor(IL.imsgInkLight)

                        VStack(alignment: .leading) {
                            Text(draft)
                                .font(IL.serif(13))
                                .foregroundColor(.white)
                                .lineSpacing(4)
                                .lineLimit(4)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(IL.imsgBlue)
                        .clipShape(BubbleShape(isOutgoing: true))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }

            // ── Bottom hints ──
            if isTopCard {
                Rectangle().fill(IL.imsgRule.opacity(0.4)).frame(height: 0.5)
                    .padding(.horizontal, 18).padding(.top, 4)

                HStack {
                    Text("← dismiss").font(IL.serif(10)).italic().foregroundColor(IL.imsgInkLight)
                    Spacer()
                    Text("↓ \(appState.snoozeLabel)")
                        .font(IL.serif(10)).italic().foregroundColor(IL.imsgInkLight)
                    Spacer()
                    Button {
                        SoundManager.shared.play(.tap)
                        appState.markAsReplied(item: email)
                    } label: {
                        Text("already replied?")
                            .font(IL.serif(10)).italic()
                            .foregroundColor(IL.imsgBlue.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Email Card Layout (editorial style with source tinting)
    // ═══════════════════════════════════════════════════════════════════════

    private var emailCardBody: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: initial circle + name + source + time ──
            HStack(spacing: 10) {
                // Sender initial circle (source-tinted gradient)
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [sourceColor, sourceColor.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 38, height: 38)
                    Text(String(email.senderName.prefix(1)).uppercased())
                        .font(IL.serif(16, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(email.senderName)
                        .font(IL.serif(16, weight: .medium))
                        .foregroundColor(IL.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        SourceIcon(source: email.source, size: 12)
                        Text(cardSourceLabel)
                            .font(IL.serif(11, weight: .medium))
                            .foregroundColor(sourceColor)
                        Text("·").foregroundColor(IL.inkFaint)
                        Text(email.priority.label)
                            .font(IL.serif(11))
                            .foregroundColor(IL.inkFaint)
                        if let tone = email.detectedTone {
                            Text("·").foregroundColor(IL.inkFaint)
                            Text(tone.capitalized)
                                .font(IL.serif(10)).italic()
                                .foregroundColor(sourceColor.opacity(0.7))
                        }
                    }
                }

                Spacer()

                Text(email.relativeTime)
                    .font(IL.serif(11))
                    .foregroundColor(IL.inkFaint)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)

            // ── Subject line ──
            if !email.subject.isEmpty {
                Text(email.subject)
                    .font(IL.serif(17, weight: .medium))
                    .foregroundColor(IL.ink)
                    .lineLimit(2).lineSpacing(3)
                    .padding(.horizontal, 18).padding(.top, 6)
            }

            // ── Body preview ──
            if email.subject.isEmpty || email.source != .gmail {
                Text(email.body)
                    .font(IL.serif(14)).foregroundColor(IL.ink.opacity(0.8))
                    .lineLimit(3).lineSpacing(4)
                    .padding(.horizontal, 18).padding(.top, email.subject.isEmpty ? 8 : 4)
            }

            // ── AI Summary ──
            if let summary = email.aiSummary {
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(sourceColor)
                        .frame(width: 16, height: 1.5)
                        .padding(.bottom, 6)
                    Text(summary)
                        .font(IL.serif(12)).italic()
                        .foregroundColor(IL.ink.opacity(0.55))
                        .lineSpacing(4).lineLimit(2)
                }
                .padding(.horizontal, 18).padding(.top, 10)
            }

            // ── Suggested reply ──
            if let draft = email.suggestedDraft, !draft.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggested reply")
                        .font(IL.serif(10, weight: .medium))
                        .foregroundColor(sourceColor.opacity(0.7))

                    Text(draftWithSignature(draft))
                        .font(IL.serif(13))
                        .foregroundColor(IL.ink.opacity(0.75))
                        .lineSpacing(4)

                    if let provSig = appState.providerSignature(for: email), !provSig.isEmpty {
                        Text(provSig)
                            .font(IL.serif(11))
                            .foregroundColor(IL.inkFaint)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 10)
            }

            // ── Chips (calendar, links, attachments) ──
            chipsSection

            // ── Bottom hints (or breathing room) ──
            if isTopCard {
                actionHints
            } else {
                Spacer().frame(height: 12)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Chat Bubble Shape
    // ═══════════════════════════════════════════════════════════════════════

    private struct BubbleShape: Shape {
        let isOutgoing: Bool

        func path(in rect: CGRect) -> Path {
            let r: CGFloat = 16
            let tail: CGFloat = 4

            if isOutgoing {
                return Path { p in
                    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
                    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
                    p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                             radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tail))
                    p.addArc(center: CGPoint(x: rect.maxX - tail, y: rect.maxY - tail),
                             radius: tail, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
                    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                             radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
                    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                             radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                }
            } else {
                return Path { p in
                    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
                    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
                    p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                             radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
                    p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                             radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                    p.addLine(to: CGPoint(x: rect.minX + tail, y: rect.maxY))
                    p.addArc(center: CGPoint(x: rect.minX + tail, y: rect.maxY - tail),
                             radius: tail, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
                    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                             radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - iMessage Data Parsers
    // ═══════════════════════════════════════════════════════════════════════

    private struct ConversationMessage {
        let text: String
        let isFromMe: Bool
        let senderName: String?
    }

    private var parsedConversationContext: [ConversationMessage]? {
        guard isIMessage,
              let raw = email.conversationContext,
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else { return nil }

        struct CtxMsg: Decodable {
            let text: String
            let isFromMe: Bool
            let senderName: String?
        }

        guard let decoded = try? JSONDecoder().decode([CtxMsg].self, from: data) else { return nil }
        return decoded.map { ConversationMessage(text: $0.text, isFromMe: $0.isFromMe, senderName: $0.senderName) }
    }

    private struct BurstMessage {
        let text: String
        let date: Date?
    }

    private func parseStructuredMessages() -> [BurstMessage] {
        guard isIMessage else { return [] }

        // Try parsing structured JSON from snippet first (from backend)
        if let data = email.snippet.data(using: .utf8) {
            struct StructuredMsg: Decodable {
                let text: String
                let date: String?
                let senderName: String?
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()

            if let structured = try? JSONDecoder().decode([StructuredMsg].self, from: data), !structured.isEmpty {
                return structured.map { m in
                    let date = m.date.flatMap { formatter.date(from: $0) ?? fallback.date(from: $0) }
                    let displayText: String
                    if let sender = m.senderName {
                        displayText = "\(sender): \(m.text)"
                    } else {
                        displayText = m.text
                    }
                    return BurstMessage(text: displayText, date: date)
                }
            }
        }

        // Fallback: parse body as newline-separated text
        let lines = email.body.components(separatedBy: "\n").filter { !$0.isEmpty }
        var messages: [BurstMessage] = []
        let tsRegex = try? NSRegularExpression(pattern: "^\\[(\\d{4}-\\d{2}-\\d{2}T[^\\]]+)\\]\\s*(.+)$")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = tsRegex?.firstMatch(in: line, range: range),
               let tsRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                let ts = String(line[tsRange])
                let text = String(line[textRange])
                let date = formatter.date(from: ts) ?? fallback.date(from: ts)
                messages.append(BurstMessage(text: text, date: date))
            } else {
                messages.append(BurstMessage(text: line, date: nil))
            }
        }
        return messages
    }

    /// Split all body messages into (olderContext, latestBurst).
    /// The latest burst = messages after the last significant time gap (≥10 min).
    /// If no timestamps or no big gap, takes the last 3 messages as the burst.
    /// Older messages get pushed into scrollable context (faded).
    private func splitLatestBurst() -> (older: [BurstMessage], latest: [BurstMessage]) {
        let all = parseStructuredMessages()
        guard all.count > 1 else { return ([], all) }

        // Find the last big gap (≥ 10 min) — everything after is the "latest burst"
        var splitIndex = 0  // default: show all as burst
        for i in stride(from: all.count - 1, through: 1, by: -1) {
            if let prev = all[i - 1].date, let curr = all[i].date {
                let gap = curr.timeIntervalSince(prev)
                if gap >= 600 { // 10 minutes
                    splitIndex = i
                    break
                }
            }
        }

        // If no big gap found but there are many messages, only show the last 3
        if splitIndex == 0 && all.count > 3 {
            splitIndex = all.count - 3
        }

        let older = Array(all.prefix(splitIndex))
        let latest = Array(all.suffix(from: splitIndex))
        return (older, latest)
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "E h:mm a"
        }
        return formatter.string(from: date)
    }

    @State private var selectedLink: DetectedLink? = nil

    // MARK: - Source-Specific Card Styling

    /// Each source gets a subtle but distinct aesthetic
    private var sourceColor: Color {
        switch email.source {
        case .imessage:  return IL.imessageGreen
        case .outlook:   return IL.outlookBlue
        case .slack:     return IL.slackPurple
        case .telegram:  return IL.telegramBlue
        case .teams:     return IL.teamsPurple
        case .groupme:   return IL.groupmeTeal
        default:         return IL.accent  // Gmail uses copper
        }
    }

    /// Card background — very subtle tint per source
    private var cardBackground: Color {
        switch email.source {
        case .imessage:  return Color(red: 0.97, green: 0.98, blue: 0.97)   // whisper green
        case .outlook:   return Color(red: 0.96, green: 0.97, blue: 0.99)   // whisper blue
        case .slack:     return Color(red: 0.98, green: 0.97, blue: 0.99)   // whisper purple
        case .teams:     return Color(red: 0.97, green: 0.97, blue: 0.99)   // whisper indigo
        case .telegram:  return Color(red: 0.96, green: 0.98, blue: 0.99)   // whisper sky
        case .groupme:   return Color(red: 0.96, green: 0.99, blue: 1.00)   // whisper teal
        default:         return IL.card                                       // warm cream (Gmail)
        }
    }

    /// Card border
    private var cardBorder: Color {
        sourceColor.opacity(0.18)
    }

    /// Rule color inside card
    private var cardRule: Color {
        sourceColor.opacity(0.12)
    }

    /// Draft box background
    private var draftBackground: Color {
        switch email.source {
        case .imessage:  return Color(red: 0.93, green: 0.96, blue: 0.93)
        case .outlook:   return Color(red: 0.93, green: 0.95, blue: 0.98)
        case .slack:     return Color(red: 0.96, green: 0.94, blue: 0.97)
        case .teams:     return Color(red: 0.94, green: 0.94, blue: 0.97)
        case .telegram:  return Color(red: 0.93, green: 0.96, blue: 0.98)
        case .groupme:   return Color(red: 0.93, green: 0.97, blue: 0.99)
        default:         return IL.cardAlt
        }
    }

    /// Corner radius — 20pt for all cards (modern, consistent)
    private var cardRadius: CGFloat { 20 }

    private func draftWithSignature(_ draft: String) -> String {
        var d = draft
        if appState.appendLedgerSignature,
           (email.source == .gmail || email.source == .outlook),
           !appState.emailSignature.isEmpty {
            d += "\n\n\(appState.emailSignature)"
        }
        return d
    }

    @ViewBuilder
    private var chipsSection: some View {
        if CalendarChip.shouldShow(for: email.body) {
            CalendarChip(emailBody: email.body, emailDate: email.date)
                .padding(.horizontal, 18).padding(.top, 8)
        }
        if !email.detectedLinks.filter({ SafariView.canOpen($0.url) }).isEmpty {
            linkChipsView
                .padding(.horizontal, 18).padding(.top, 6)
        }
        if email.hasAttachments {
            attachmentChipsView
                .padding(.horizontal, 18).padding(.top, 6)
        }
    }

    private var actionHints: some View {
        VStack(spacing: 0) {
            Rectangle().fill(cardRule).frame(height: 0.5)
                .padding(.horizontal, 18).padding(.top, 4)
            HStack {
                Text("← dismiss").font(IL.serif(10)).italic().foregroundColor(IL.inkFaint)
                Spacer()
                Text("↓ \(appState.snoozeLabel)")
                    .font(IL.serif(10)).italic().foregroundColor(IL.inkFaint)
                Spacer()
                Button {
                    SoundManager.shared.play(.tap)
                    appState.markAsReplied(item: email)
                } label: {
                    Text("already replied?")
                        .font(IL.serif(10)).italic()
                        .foregroundColor(sourceColor.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    // MARK: - Link Chips

    private var linkChipsView: some View {
        let safeLinks = email.detectedLinks.filter { SafariView.canOpen($0.url) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(safeLinks.prefix(4)) { link in
                    Button {
                        // Only open links that are safe for SFSafariViewController
                        if SafariView.canOpen(link.url) {
                            selectedLink = link
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: link.linkType.icon)
                                .font(.system(size: 10, weight: .medium))
                            Text(link.displayText)
                                .font(IL.serif(10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(link.linkType.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(link.linkType.color.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(link.linkType.color.opacity(0.20), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Attachment Chips

    private var attachmentChipsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(email.realAttachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.fileType.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(truncatedFilename(attachment.filename))
                            .font(IL.serif(10, weight: .medium))
                            .lineLimit(1)
                        Text(attachment.formattedSize)
                            .font(IL.serif(9))
                            .foregroundColor(attachment.fileType.color.opacity(0.6))
                    }
                    .foregroundColor(attachment.fileType.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(attachment.fileType.color.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(attachment.fileType.color.opacity(0.20), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    private func truncatedFilename(_ name: String) -> String {
        if name.count <= 20 { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let truncBase = String(base.prefix(14))
        return "\(truncBase)….\(ext)"
    }

    private func handleSwipe(_ translation: CGFloat) {
        if translation > threshold {
            // Swipe right → Send
            SoundManager.shared.play(.send)
            withAnimation(.easeOut(duration: 0.3)) { offset = 500 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if email.source == .imessage {
                    if let draft = email.suggestedDraft, !draft.isEmpty {
                        appState.queueSend(for: email, body: draft, replyAll: false)
                    } else {
                        appState.dismiss(item: email)
                    }
                } else if let draft = email.suggestedDraft {
                    var sendBody = draft
                    if appState.appendLedgerSignature,
                       (email.source == .gmail || email.source == .outlook),
                       !appState.emailSignature.isEmpty,
                       !sendBody.contains(appState.emailSignature) {
                        sendBody += "\n\n\(appState.emailSignature)"
                    }
                    appState.queueSend(for: email, body: sendBody, replyAll: false)
                } else {
                    appState.dismiss(item: email)
                }
            }
        } else if translation < -threshold {
            // Swipe left → Dismiss
            SoundManager.shared.play(.dismiss)
            withAnimation(.easeOut(duration: 0.3)) { offset = -500 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                appState.dismiss(item: email)
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                offset = 0
                offsetY = 0
            }
        }
    }

    private func handleSnooze() {
        SoundManager.shared.play(.snooze)
        withAnimation(.easeOut(duration: 0.3)) { offsetY = 600 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            appState.snooze(item: email)
        }
    }
}

#if DEBUG
struct EmailCardView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            IL.paper.ignoresSafeArea()
            EmailCardView(email: .preview, isTopCard: true, maxHeight: 500)
                .padding().environmentObject(AppState())
        }
    }
}
#endif

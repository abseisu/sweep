// DashboardView.swift
// Ledger

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var showDismissed = false
    @State private var timeRemaining: String = ""
    @State private var showFirstRunBanner = true
    @State private var showModeSwitchBanner = true

    // Timer to update countdown
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            IL.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                // New account scanning indicator
                if let serviceName = appState.isScanningNewAccount {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(IL.inkFaint)
                        Text("Scanning \(serviceName)…")
                            .font(IL.serif(12)).italic()
                            .foregroundColor(IL.paperInkLight)
                    }
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.3), value: appState.isScanningNewAccount)
                }

                if appState.isLoading {
                    loadingView
                    Spacer(minLength: 0)
                } else if appState.items.isEmpty {
                    emptyView
                    Spacer(minLength: 0)
                } else {
                    // Contextual banner (show at most one)
                    if showFirstRunBanner && appState.isFirstSession {
                        // First-ever 7-day scan just completed
                        firstRunBanner
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let fromMode = appState.switchedFromMode, showModeSwitchBanner {
                        // Just switched modes — explain the narrower scan
                        modeSwitchBanner(from: fromMode)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !appState.dismissedItems.isEmpty {
                        // Normal undo banner (only within the same mode session)
                        undoBanner
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // "Earlier this week" divider when top card is from days 2–7
                    if let topItem = appState.items.first, topItem.isEarlierThisWeek {
                        earlierThisWeekDivider
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Full-height card — fills all remaining space
                    cardStackView
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showDismissed) { DismissedView() }
        .overlay(alignment: .bottom) {
            if let pending = appState.pendingSend {
                undoSendToast(name: pending.contactName, countdown: appState.pendingSendCountdown)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.pendingSend != nil)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            updateTimeRemaining()
            // Try to restore persisted ledger state (survives app termination)
            if !appState.hasFetchedThisWindow && !appState.isLoading {
                if appState.restoreLedgerState() {
                    // State restored — items are ready, no need to re-fetch
                    print("📱 Ledger restored from disk — skipping fetch")
                } else {
                    Task { await appState.fetchAndProcess() }
                }
            }
        }
        .onReceive(timer) { _ in
            updateTimeRemaining()
            // Auto-lock when time expires (window mode only)
            if appState.ledgerMode == .window,
               let expires = appState.lockExpiresAt, Date() >= expires {
                appState.lock()
            }
        }
    }

    private func updateTimeRemaining() {
        if appState.ledgerMode == .window {
            timeRemaining = appState.timeRemainingDescription ?? ""
        } else {
            timeRemaining = ""
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Sweep")
                            .font(IL.serif(26, weight: .regular))
                            .foregroundColor(IL.paperInk)

                        if appState.ledgerMode == .window && !timeRemaining.isEmpty {
                            Text(timeRemaining)
                                .font(IL.serif(11))
                                .italic()
                                .foregroundColor(IL.accent)
                        } else if appState.ledgerMode == .stack && !appState.items.isEmpty {
                            Text("~\(appState.estimatedClearMinutes) min")
                                .font(IL.serif(11))
                                .italic()
                                .foregroundColor(IL.paperInkFaint)
                        }
                    }

                    if !appState.items.isEmpty {
                        let totalCount = appState.items.count
                        let mustCount = appState.items.filter { $0.priority == .must }.count

                        HStack(spacing: 0) {
                            if mustCount > 0 {
                                Text("\(mustCount) urgent")
                                    .font(IL.serif(12, weight: .medium))
                                    .foregroundColor(LedgerPriority.must.color)
                                if totalCount > mustCount {
                                    Text(" · ").font(IL.serif(12)).foregroundColor(IL.paperInkFaint)
                                }
                            }
                            let otherCount = totalCount - mustCount
                            if otherCount > 0 {
                                Text("\(otherCount) worth a reply")
                                    .font(IL.serif(12)).italic()
                                    .foregroundColor(LedgerPriority.should.color)
                            }
                        }
                        .padding(.top, 3)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    if !appState.snoozedItems.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 11, weight: .light))
                            Text("\(appState.snoozedItems.count)")
                                .font(IL.serif(11))
                        }
                        .foregroundColor(Color(red: 0.25, green: 0.35, blue: 0.55))
                    }

                    if !appState.dismissedItems.isEmpty {
                        Button { showDismissed = true } label: {
                            Image(systemName: "tray")
                                .font(.system(size: 16, weight: .light))
                                .foregroundColor(IL.paperInkLight)
                        }
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(IL.paperInk)
                    }
                }
            }

            VStack(spacing: 2) {
                Rectangle().fill(IL.paperInk.opacity(0.15)).frame(height: 1)
                Rectangle().fill(IL.paperInk.opacity(0.08)).frame(height: 0.5)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Undo

    private var undoBanner: some View {
        Button { SoundManager.shared.play(.tap); appState.undoDismiss() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                Text("Undo — bring back \(appState.dismissedItems.first?.senderName ?? "last")")
                    .font(IL.serif(12)).lineLimit(1)
            }
            .foregroundColor(IL.accent)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(IL.accent.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .overlay(
                RoundedRectangle(cornerRadius: IL.radius)
                    .stroke(IL.accent.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    // MARK: - First Run Banner

    private var firstRunBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(IL.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your first sweep")
                    .font(IL.serif(12, weight: .medium))
                    .foregroundColor(IL.paperInk)
                Text("These are emails from the past 7 days that may need a reply. Going forward, Sweep checks only for new arrivals.")
                    .font(IL.serif(10))
                    .foregroundColor(IL.paperInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    showFirstRunBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(IL.paperInkFaint)
                    .padding(6)
            }
        }
        .padding(12)
        .background(IL.accent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
        .overlay(
            RoundedRectangle(cornerRadius: IL.radius)
                .stroke(IL.accent.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Undo Send Toast

    private func undoSendToast(name: String, countdown: Int) -> some View {
        HStack(spacing: 12) {
            // Countdown ring
            ZStack {
                Circle()
                    .stroke(IL.ink.opacity(0.1), lineWidth: 2)
                    .frame(width: 28, height: 28)
                Circle()
                    .trim(from: 0, to: CGFloat(countdown) / CGFloat(appState.undoSendWindow))
                    .stroke(IL.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: countdown)
                Text("\(countdown)")
                    .font(IL.serif(10, weight: .medium))
                    .foregroundColor(IL.paperInk)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Sent to \(name)")
                    .font(IL.serif(13, weight: .medium))
                    .foregroundColor(IL.paperInk)
                    .lineLimit(1)
                Text("Sending in \(countdown)s…")
                    .font(IL.serif(10))
                    .foregroundColor(IL.paperInkFaint)
            }

            Spacer()

            Button {
                SoundManager.shared.play(.undoSend)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appState.undoSend()
                }
            } label: {
                Text("Undo")
                    .font(IL.serif(13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(IL.paperInk)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(IL.paper)
                .shadow(color: IL.ink.opacity(0.12), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(IL.ink.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Earlier This Week Divider

    private var earlierThisWeekDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(IL.paperInk.opacity(0.1)).frame(height: 0.5)
            Text("Earlier this week")
                .font(IL.serif(11)).italic()
                .foregroundColor(IL.paperInkFaint)
                .layoutPriority(1)
            Rectangle().fill(IL.paperInk.opacity(0.1)).frame(height: 0.5)
        }
    }

    // MARK: - Mode Switch Banner

    private func modeSwitchBanner(from previousMode: LedgerMode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(IL.ink.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text("Picking up where you left off")
                    .font(IL.serif(12, weight: .medium))
                    .foregroundColor(IL.paperInk)
                Text("Only showing new emails since your last \(previousMode.title) run.")
                    .font(IL.serif(10))
                    .foregroundColor(IL.paperInkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    showModeSwitchBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(IL.paperInkFaint)
                    .padding(6)
            }
        }
        .padding(12)
        .background(IL.paperInk.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
        .overlay(
            RoundedRectangle(cornerRadius: IL.radius)
                .stroke(IL.ink.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().tint(IL.inkLight)

            if appState.isFirstRunActive {
                VStack(spacing: 8) {
                    Text("Scanning your past week…")
                        .font(IL.serif(14)).italic().foregroundColor(IL.paperInk)
                    Text("Your first sweep looks back 7 days to find\nconversations that may still need a reply.")
                        .font(IL.serif(11))
                        .foregroundColor(IL.paperInkFaint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(appState.isProcessingAI ? "Reading between the lines…" : "Gathering your correspondence…")
                    .font(IL.serif(14)).italic().foregroundColor(IL.paperInkLight)
            }

            Spacer()
        }
    }

    // MARK: - Empty

    @State private var showCheckIn = false
    @State private var checkInAnswered = false

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()

            // Check-in card — appears after clearing ~5 items
            if StyleMemory.shared.shouldShowCheckIn && !checkInAnswered,
               let question = StyleMemory.shared.nextCheckIn {
                checkInCard(question: question)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 16)
            }

            clearedLedgerView

            Spacer()
        }
    }

    // MARK: - Cleared Ledger Celebration

    private var clearedLedgerView: some View {
        let stats = LedgerStats.shared
        let repliedCount = stats.lastSessionReplies
        let contacts = stats.lastSessionContacts
        let streak = stats.currentStreak
        let totalDays = stats.totalClearedDays

        return VStack(spacing: 0) {
            // Ornamental flourish
            VStack(spacing: 2) {
                Rectangle().fill(IL.ink).frame(height: 0.5)
                Rectangle().fill(IL.ink).frame(height: 1.5)
            }
            .frame(width: 60)
            .padding(.bottom, 20)

            // Headline — varies based on context
            Text(clearedHeadline(repliedCount: repliedCount, streak: streak))
                .font(IL.serif(24, weight: .regular))
                .foregroundColor(IL.paperInk)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            // Subtitle
            Text(clearedSubtitle(repliedCount: repliedCount, contacts: contacts))
                .font(IL.serif(14)).italic()
                .foregroundColor(IL.paperInkLight)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)

            // Stats strip
            if repliedCount > 0 || streak > 1 || totalDays > 1 {
                HStack(spacing: 24) {
                    if repliedCount > 0 {
                        statPill(value: "\(repliedCount)", label: repliedCount == 1 ? "reply" : "replies")
                    }
                    if streak > 1 {
                        statPill(value: "\(streak)", label: "day streak")
                    }
                    if totalDays > 1 && streak <= 1 {
                        statPill(value: "\(totalDays)", label: "days cleared")
                    }
                }
                .padding(.bottom, 20)
            }

            // Streak dots — this week
            if totalDays > 0 {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 3) {
                            Circle()
                                .fill(stats.weekDots[i] ? IL.ink : IL.ink.opacity(0.1))
                                .frame(width: 8, height: 8)
                            Text(stats.weekDayLabels[i])
                                .font(IL.serif(8))
                                .foregroundColor(IL.paperInkFaint)
                        }
                    }
                }
                .padding(.bottom, 20)
            }

            // Closing line
            VStack(spacing: 2) {
                Rectangle().fill(IL.ink).frame(height: 1.5)
                Rectangle().fill(IL.ink).frame(height: 0.5)
            }
            .frame(width: 40)
            .padding(.bottom, 16)

            Text(closingLine)
                .font(IL.serif(12)).italic()
                .foregroundColor(IL.paperInkFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)

            // Buttons
            HStack(spacing: 16) {
                Button {
                    Task { await appState.checkForNewItems() }
                } label: {
                    Text("Check again").font(IL.serif(14)).foregroundColor(IL.paperInk)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: IL.radius)
                                .stroke(IL.inkFaint, lineWidth: 0.5)
                        )
                }
                if !appState.dismissedItems.isEmpty {
                    Button { showDismissed = true } label: {
                        Text("View dismissed").font(IL.serif(14)).italic()
                            .foregroundColor(IL.paperInkLight)
                    }
                }
            }
        }
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(IL.serif(20, weight: .medium))
                .foregroundColor(IL.paperInk)
            Text(label)
                .font(IL.serif(10)).italic()
                .foregroundColor(IL.paperInkFaint)
        }
    }

    private func clearedHeadline(repliedCount: Int, streak: Int) -> String {
        if repliedCount == 0 {
            return "All Clear"
        }
        let headlines: [String]
        if streak >= 7 {
            headlines = ["A full week.", "Seven for seven.", "Unstoppable."]
        } else if streak >= 3 {
            headlines = ["On a roll.", "Ledger cleared.", "Well kept."]
        } else if repliedCount >= 5 {
            headlines = ["Prolific evening.", "Thoroughly done.", "Every last one."]
        } else if repliedCount >= 3 {
            headlines = ["Nicely done.", "Ledger cleared.", "All caught up."]
        } else {
            headlines = ["Done for tonight.", "Ledger balanced.", "All clear."]
        }
        let dayIndex = Calendar.current.component(.day, from: Date())
        return headlines[dayIndex % headlines.count]
    }

    private func clearedSubtitle(repliedCount: Int, contacts: [String]) -> String {
        if repliedCount == 0 {
            if appState.isFirstSession {
                return "Nothing from the past week needs your attention.\nLedger will check for new emails going forward."
            }
            return "Nothing needs your attention\nfrom the past twenty-four hours."
        }
        if contacts.count == 1 {
            return "You wrote back to \(contacts[0])."
        }
        if contacts.count == 2 {
            return "You wrote back to \(contacts[0]) and \(contacts[1])."
        }
        if contacts.count <= 4 {
            let last = contacts.last!
            let rest = contacts.dropLast().joined(separator: ", ")
            return "You wrote back to \(rest),\nand \(last)."
        }
        let shown = contacts.prefix(3).joined(separator: ", ")
        let remaining = contacts.count - 3
        return "You wrote back to \(shown),\nand \(remaining) others."
    }

    private var closingLine: String {
        let windowLines = [
            "Go enjoy your evening.",
            "The rest of the night is yours.",
            "Nothing left but the night ahead.",
            "Close the app. Open a book.",
            "Your inbox can wait until tomorrow.",
            "Time well spent.",
            "Step away. You've earned it.",
        ]
        let stackLines = [
            "All caught up.",
            "Nothing needs your attention.",
            "Close the app. You're good.",
            "Back to your day.",
            "Time well spent.",
            "Check back later — or don't.",
            "Inbox zero, Ledger style.",
        ]
        let lines = appState.ledgerMode == .window ? windowLines : stackLines
        let minute = Calendar.current.component(.minute, from: Date())
        return lines[minute % lines.count]
    }

    private func checkInCard(question: StyleMemory.CheckInQuestion) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(IL.accent)
                Text("Help Sweep learn your style")
                    .font(IL.serif(11)).italic()
                    .foregroundColor(IL.accent)
            }

            Text(question.question)
                .font(IL.serif(15, weight: .medium))
                .foregroundColor(IL.paperInk)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            StyleMemory.shared.answerCheckIn(questionId: question.id, answer: option)
                            checkInAnswered = true
                        }
                    } label: {
                        Text(option)
                            .font(IL.serif(13))
                            .foregroundColor(IL.paperInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                            .overlay(
                                RoundedRectangle(cornerRadius: IL.radius)
                                    .stroke(IL.rule, lineWidth: 0.5)
                            )
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    checkInAnswered = true
                }
            } label: {
                Text("Skip").font(IL.serif(11)).italic()
                    .foregroundColor(IL.paperInkFaint)
            }
        }
        .padding(20)
        .background(IL.paper)
        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
        .overlay(
            RoundedRectangle(cornerRadius: IL.radius)
                .stroke(IL.accent.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 32)
    }

    // MARK: - Cards (content-hugging with decorative deck edge)

    private var cardStackView: some View {
        VStack(spacing: 0) {
            let visibleCards = Array(appState.items.prefix(3))

            if !visibleCards.isEmpty {
                ZStack(alignment: .top) {
                    // Decorative "deck" edge — hints at more cards underneath
                    if visibleCards.count > 1 {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(IL.card.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                            )
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                            .frame(height: 20)
                    }

                    // Render all 3 cards so SwiftUI can animate transitions,
                    // but only the top card is visible — back cards are fully
                    // hidden behind it (opacity 0, no offset).
                    ForEach(Array(visibleCards.enumerated().reversed()), id: \.element.id) { index, item in
                        let isTop = index == 0

                        EmailCardView(email: item, isTopCard: isTop)
                            .opacity(isTop ? 1 : 0)
                            .zIndex(Double(visibleCards.count - index))
                            .allowsHitTesting(isTop)
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .opacity.combined(with: .move(edge: .trailing))
                            ))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.items.map(\.id))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 20)
    }
}

// MARK: - Dismissed Items

struct DismissedView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                IL.paper.ignoresSafeArea()

                if appState.dismissedItems.isEmpty {
                    Text("Nothing dismissed")
                        .font(IL.serif(16)).italic().foregroundColor(IL.paperInkLight)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(appState.dismissedItems) { item in
                                dismissedRow(item)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Dismissed").font(IL.serif(16)).italic()
                        .foregroundColor(IL.paperInkLight)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done").font(IL.serif(15, weight: .medium))
                            .foregroundColor(IL.paperInk)
                    }
                }
            }
        }
    }

    private func dismissedRow(_ item: LedgerEmail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(item.priority.color).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.senderName).font(IL.serif(14, weight: .medium)).foregroundColor(IL.paperInk)
                Text(item.subject.isEmpty ? item.snippet : item.subject)
                    .font(IL.serif(12)).foregroundColor(IL.paperInkLight).lineLimit(1)
                Text(item.relativeTime).font(IL.serif(10)).foregroundColor(IL.paperInkFaint)
            }
            Spacer()
            Button { appState.restore(item: item) } label: {
                Text("Restore").font(IL.serif(12)).foregroundColor(IL.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: IL.radius)
                            .stroke(IL.accent.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
        .overlay(
            RoundedRectangle(cornerRadius: IL.radius)
                .stroke(IL.rule, lineWidth: 0.5)
        )
    }
}

#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let state = AppState()
        state.accounts = [ConnectedAccount(id: "test@gmail.com", service: .gmail, displayName: "Test", identifier: "test@gmail.com", accessToken: "")]
        state.isUnlocked = true
        state.lockExpiresAt = Date().addingTimeInterval(2400)
        state.items = LedgerEmail.previewList
        state.dismissedItems = [.previewLow]
        return NavigationStack {
            DashboardView().environmentObject(state)
        }
    }
}
#endif


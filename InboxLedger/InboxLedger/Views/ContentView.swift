// ContentView.swift
// Ledger

import SwiftUI
import UIKit

// MARK: - iOS Compatibility

/// Applies .scrollDismissesKeyboard(.interactively) on iOS 16+, no-op on iOS 15
struct ScrollDismissKeyboardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

/// Applies .scrollContentBackground(.hidden) on iOS 16+, no-op on iOS 15
struct HideScrollBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

// MARK: - Design Tokens

enum IL {
    // ── Sweep (Dusk) Theme ──
    // Background: deep navy. Cards: warm cream. Accent: copper.
    static let paper = Color(red: 0.067, green: 0.094, blue: 0.125)       // #111820 — deep navy bg
    static let elevated = Color(red: 0.098, green: 0.133, blue: 0.180)    // #19222E

    // Card surface colors (warm cream)
    static let card = Color(red: 0.957, green: 0.941, blue: 0.910)        // #F4F0E8
    static let cardAlt = Color(red: 0.922, green: 0.902, blue: 0.863)     // #EBE6DC

    // PRIMARY text colors — these work on card (cream) surfaces.
    // Since most of the app UI is cards, ink/inkLight/inkFaint are dark tones.
    static let ink = Color(red: 0.102, green: 0.094, blue: 0.082)         // #1A1815 — dark, for card text
    static let inkLight = Color(red: 0.290, green: 0.275, blue: 0.251)    // #4A4640 — medium, for card secondary
    static let inkFaint = Color(red: 0.541, green: 0.522, blue: 0.486)    // #8A857C — light, for card tertiary
    static let inkWhisper = Color(red: 0.102, green: 0.094, blue: 0.082).opacity(0.06) // subtle on card

    // Text on DARK (paper/navy) background — light tones.
    // Use these ONLY for text/icons that sit directly on IL.paper.
    static let paperInk = Color(red: 0.910, green: 0.886, blue: 0.839)         // #E8E2D6 — primary on dark
    static let paperInkLight = Color(red: 0.541, green: 0.588, blue: 0.651)    // #8A96A6 — secondary on dark
    static let paperInkFaint = Color(red: 0.353, green: 0.408, blue: 0.471)    // #5A6878 — tertiary on dark

    // Accent
    static let accent = Color(red: 0.80, green: 0.50, blue: 0.27)         // #CC8044 — copper
    static let accentDeep = Color(red: 0.659, green: 0.408, blue: 0.188)  // #A86830

    // Rules
    static let rule = Color(red: 0.102, green: 0.094, blue: 0.082).opacity(0.10) // subtle on card
    static let ruleOnCard = Color(red: 0.867, green: 0.847, blue: 0.800)        // #DDD8CC
    static let paperRule = Color(red: 0.910, green: 0.886, blue: 0.839).opacity(0.10) // subtle on dark

    // Status & service colors
    static let success = Color(red: 0.29, green: 0.54, blue: 0.33)
    static let imessageGreen = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let outlookBlue = Color(red: 0.0, green: 0.34, blue: 0.59)
    static let slackPurple = Color(red: 0.38, green: 0.15, blue: 0.42)
    static let telegramBlue = Color(red: 0.16, green: 0.47, blue: 0.71)
    static let teamsPurple = Color(red: 0.29, green: 0.21, blue: 0.55)
    static let groupmeTeal = Color(red: 0.00, green: 0.64, blue: 0.87)

    // iMessage card colors
    static let imsgBlue = Color(red: 0.133, green: 0.478, blue: 0.992)
    static let imsgBubble = Color(red: 0.898, green: 0.933, blue: 0.992)
    static let imsgCard = Color(red: 0.976, green: 0.980, blue: 0.992)
    static let imsgRule = Color(red: 0.847, green: 0.878, blue: 0.925)
    static let imsgInkLight = Color(red: 0.420, green: 0.490, blue: 0.580)
    static let imsgSummaryInk = Color(red: 0.380, green: 0.455, blue: 0.545)

    static let surface = Color(red: 0.98, green: 0.97, blue: 0.96)
    static let radius: CGFloat = 4

    // MARK: - Responsive Scaling

    /// Screen width scale factor: 1.0 on standard iPhone (393pt), ~0.95 on SE (375pt), ~1.07 on Pro Max (430pt)
    static let screenScale: CGFloat = {
        let width = UIScreen.main.bounds.width
        return min(max(width / 393.0, 0.85), 1.15)  // Clamp between 0.85x and 1.15x
    }()

    /// Whether this is a compact-width device (SE, mini)
    static let isCompact: Bool = UIScreen.main.bounds.width < 380

    /// Responsive horizontal padding — tighter on small screens
    static let pagePadding: CGFloat = isCompact ? 20 : 32

    /// Responsive serif font that scales with screen size
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = isCompact ? size * 0.9 : size
        return .system(size: scaled, weight: weight, design: .serif)
    }

    /// Scaled value — use for widths, heights, spacing that should adapt
    static func scaled(_ value: CGFloat) -> CGFloat {
        value * screenScale
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isReady {
                OnboardingView()
                    .transition(.opacity)
            } else if appState.isLocked {
                LockScreenView()
                    .transition(.opacity)
            } else {
                NavigationStack {
                    DashboardView()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: appState.isReady)
        .animation(.easeInOut(duration: 0.4), value: appState.isUnlocked)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if appState.ledgerMode == .window {
                appState.checkAutoUnlock()
            }
            // User is in the app — suppress notifications
            NotificationManager.shared.cancelAllNags()
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["com.inboxledger.cleared", "com.inboxledger.batch-ready"]
            )
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()

            // Stack mode: refresh stack if stale
            if appState.ledgerMode == .stack {
                Task { await appState.stackModeAppOpened() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // If ledger was cleared THIS session, send congrats ONCE
            if appState.ledgerWasCleared {
                NotificationManager.shared.sendClearedNotification()
                appState.ledgerWasCleared = false
                return
            }

            if appState.ledgerMode == .window {
                // Window mode: schedule nags if window still open
                if appState.isUnlocked, !appState.items.isEmpty,
                   let expires = appState.lockExpiresAt, Date() < expires {
                    let now = Date()
                    let minutesLeft = Int(expires.timeIntervalSince(now) / 60)
                    guard minutesLeft > 5 else { return }
                    NotificationManager.shared.scheduleRemainingNags(
                        startingAt: now.addingTimeInterval(300),
                        until: expires
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgerPostpone)) { _ in
            appState.postponeWindow()
        }
    }
}

// MARK: - Lock Screen

struct LockScreenView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var visible = false
    @State private var quoteVisible = false
    @State private var showOpenEarlyConfirm = false
    @State private var showPostponePicker = false
    @State private var postponeDate = Date()
    @State private var now = Date()

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let quote = QuoteEngine.todaysQuote()

    /// Alternates between personal stats and literary quotes.
    /// Even days: personal stat (if available). Odd days: quote.
    private var lockScreenMessage: String? {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        // Show personal message on even days, quote on odd — but only if we have data
        if dayOfYear % 2 == 0 {
            return LedgerStats.shared.personalMessage()
        }
        return nil  // nil = show the literary quote
    }

    var body: some View {
        ZStack {
            IL.paper.ignoresSafeArea()

            // Ambient floating ink particles
            FloatingInkView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: date line + settings
                HStack {
                    DateLineView()
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(IL.paperInkLight)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .opacity(visible ? 1 : 0)

                Spacer()

                // Main content
                VStack(spacing: 0) {
                    // Masthead
                    VStack(spacing: 2) {
                        Rectangle().fill(IL.paperInk).frame(height: 1.5)
                        Rectangle().fill(IL.paperInk).frame(height: 0.5)
                    }
                    .frame(width: 120)
                    .padding(.bottom, 20)

                    Text("Sweep")
                        .font(IL.serif(38, weight: .regular))
                        .foregroundColor(IL.paperInk)

                    Rectangle()
                        .fill(IL.paperInk)
                        .frame(width: 40, height: 0.5)
                        .padding(.top, 14)

                    // Lock message
                    if appState.hasUsedTodaysWindow {
                        VStack(spacing: 8) {
                            Text("Today's window has closed")
                                .font(IL.serif(14)).italic()
                                .foregroundColor(IL.paperInkLight)
                            Text("Come back tomorrow at")
                                .font(IL.serif(13))
                                .foregroundColor(IL.paperInkFaint)
                            Text(formattedScheduledTime)
                                .font(IL.serif(28, weight: .light))
                                .foregroundColor(IL.paperInk)
                        }
                        .padding(.top, 24)
                    } else {
                        VStack(spacing: 8) {
                            Text("Your sweep opens")
                                .font(IL.serif(14)).italic()
                                .foregroundColor(IL.paperInkLight)
                            Text(formattedUnlockTime)
                                .font(IL.serif(28, weight: .light))
                                .foregroundColor(IL.paperInk)
                            Text(countdownText)
                                .font(IL.serif(13)).italic()
                                .foregroundColor(IL.paperInkFaint)
                        }
                        .padding(.top, 24)

                        HStack(spacing: 12) {
                            // Open Early button — shows confirmation first
                            Button {
                                showOpenEarlyConfirm = true
                            } label: {
                                Text("Open now")
                                    .font(IL.serif(13))
                                    .foregroundColor(IL.paperInk)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 9)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: IL.radius)
                                            .stroke(IL.paperInkFaint, lineWidth: 0.5)
                                    )
                            }

                            // Change time button — always available before window opens
                            Button {
                                // Default to 1 hour after the scheduled window time
                                let cal = Calendar.current
                                var components = cal.dateComponents([.year, .month, .day], from: Date())
                                components.hour = (appState.notificationHour + 1) % 24
                                components.minute = appState.notificationMinute
                                if let defaultTime = cal.date(from: components) {
                                    // If that time is in the past, use 1 hour from now
                                    postponeDate = defaultTime > Date() ? defaultTime : Date().addingTimeInterval(3600)
                                } else {
                                    postponeDate = Date().addingTimeInterval(3600)
                                }

                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showPostponePicker.toggle()
                                }
                            } label: {
                                Text(showPostponePicker ? "Cancel" : "Change time")
                                    .font(IL.serif(13)).italic()
                                    .foregroundColor(IL.paperInkFaint)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                            }
                        }
                        .padding(.top, 16)

                        // Inline time picker for postpone
                        if showPostponePicker {
                            VStack(spacing: 12) {
                                Text("Open today at")
                                    .font(IL.serif(12)).italic()
                                    .foregroundColor(IL.paperInkFaint)

                                DatePicker(
                                    "",
                                    selection: $postponeDate,
                                    in: Date()...Calendar.current.date(byAdding: .hour, value: 12, to: Date())!,
                                    displayedComponents: .hourAndMinute
                                )
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                                .frame(height: 120)
                                .clipped()

                                Button {
                                    let cal = Calendar.current
                                    let h = cal.component(.hour, from: postponeDate)
                                    let m = cal.component(.minute, from: postponeDate)
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        appState.postponeToTime(hour: h, minute: m)
                                        showPostponePicker = false
                                    }
                                } label: {
                                    Text("Confirm")
                                        .font(IL.serif(14, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 28)
                                        .padding(.vertical, 10)
                                        .background(IL.paperInk)
                                        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                                }
                            }
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .opacity(visible ? 1 : 0)

                Spacer()

                // Streak dots (last 7 days)
                if LedgerStats.shared.totalClearedDays > 0 {
                    VStack(spacing: 6) {
                        // Day labels
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                let dayOffset = i - 6 // -6 to 0 (today)
                                let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date())!
                                let letter = dayLetter(for: date)
                                Text(letter)
                                    .font(IL.serif(8))
                                    .foregroundColor(IL.paperInkFaint)
                                    .frame(width: 6)
                            }
                        }
                        // Dots
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                Circle()
                                    .fill(LedgerStats.shared.weekDots[i] ? IL.ink : IL.ink.opacity(0.12))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        if LedgerStats.shared.currentStreak > 1 {
                            Text("\(LedgerStats.shared.currentStreak)-day streak")
                                .font(IL.serif(10))
                                .foregroundColor(IL.paperInkFaint)
                        }
                    }
                    .opacity(quoteVisible ? 1 : 0)
                }

                Spacer().frame(height: 16)

                // Alternate: personal stat message OR literary quote
                VStack(spacing: 6) {
                    if let personal = lockScreenMessage {
                        Text(personal)
                            .font(IL.serif(14)).italic()
                            .foregroundColor(IL.paperInkLight)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\u{201c}\(quote.text)\u{201d}")
                            .font(IL.serif(14)).italic()
                            .foregroundColor(IL.paperInkLight)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\u{2014} \(quote.author)")
                            .font(IL.serif(11))
                            .foregroundColor(IL.paperInkFaint)
                    }
                }
                .padding(.horizontal, IL.isCompact ? 24 : 40)
                .opacity(quoteVisible ? 1 : 0)
                .offset(y: quoteVisible ? 0 : 8)

                Spacer().frame(height: 24)

                // Calendar conflict suggestion
                if let conflict = appState.windowConflict {
                    VStack(spacing: 10) {
                        Text(conflict.message)
                            .font(IL.serif(13))
                            .foregroundColor(IL.paperInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)

                        Button {
                            appState.acceptConflictSuggestion(conflict)
                        } label: {
                            Text("Yes, move to \(conflict.formatSuggestedTime)")
                                .font(IL.serif(13, weight: .medium))
                                .foregroundColor(IL.paper)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(IL.paperInk)
                                .cornerRadius(IL.radius)
                        }

                        Button {
                            appState.dismissConflictSuggestion()
                        } label: {
                            Text("Keep original time")
                                .font(IL.serif(11))
                                .foregroundColor(IL.paperInkFaint)
                        }
                    }
                    .padding(.horizontal, IL.pagePadding)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: IL.radius)
                            .fill(IL.paper)
                            .shadow(color: IL.ink.opacity(0.06), radius: 6, y: 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: IL.radius)
                                    .stroke(IL.paperInkFaint.opacity(0.3), lineWidth: 0.5)
                            )
                    )
                    .padding(.horizontal, 24)
                    .opacity(quoteVisible ? 1 : 0)
                }

                Spacer().frame(height: 16)

                // Change schedule
                Button { showSettings = true } label: {
                    Text("Change schedule")
                        .font(IL.serif(12))
                        .foregroundColor(IL.paperInkFaint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(
                            RoundedRectangle(cornerRadius: IL.radius)
                                .stroke(IL.paperInkFaint.opacity(0.3), lineWidth: 0.5)
                        )
                }
                .padding(.bottom, 36)
                .opacity(quoteVisible ? 1 : 0)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Open your ledger now?", isPresented: $showOpenEarlyConfirm) {
            Button("Open now") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState.openEarly()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You get one window per day. Once opened, your hour starts immediately and can't be paused.")
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) { visible = true }
            withAnimation(.easeOut(duration: 0.8).delay(0.6)) { quoteVisible = true }
        }
        .onReceive(countdownTimer) { _ in
            now = Date()
        }
    }

    private func dayLetter(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE" // Single letter: M, T, W, T, F, S, S
        return formatter.string(from: date)
    }

    private var formattedUnlockTime: String {
        let h = appState.effectiveHour
        let m = appState.effectiveMinute
        let period = h >= 12 ? "PM" : "AM"
        let displayH = h > 12 ? h - 12 : (h == 0 ? 12 : h)
        return "\(displayH):\(String(format: "%02d", m)) \(period)"
    }

    /// Live countdown that updates every second via the timer
    private var countdownText: String {
        let cal = Calendar.current
        var components = DateComponents()
        components.hour = appState.effectiveHour
        components.minute = appState.effectiveMinute
        guard let nextFire = cal.nextDate(after: now, matching: components, matchingPolicy: .nextTime) else {
            return ""
        }
        let diff = cal.dateComponents([.hour, .minute, .second], from: now, to: nextFire)
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0
        let s = diff.second ?? 0

        if h == 0 && m == 0 {
            return "in \(s)s"
        } else if h == 0 {
            return "in \(m)m"
        }
        return "in \(h)h \(m)m"
    }

    /// Always shows the regular scheduled time (not postponed) — for "come back tomorrow"
    private var formattedScheduledTime: String {
        let h = appState.notificationHour
        let m = appState.notificationMinute
        let period = h >= 12 ? "PM" : "AM"
        let displayH = h > 12 ? h - 12 : (h == 0 ? 12 : h)
        return "\(displayH):\(String(format: "%02d", m)) \(period)"
    }

}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage = 0
    @State private var connecting: AccountService? = nil
    @State private var errorMessage: String?
    @State private var showIMessageSetup = false
    @State private var visible = false
    @State private var calendarGranted = CalendarManager.shared.isAuthorized
    @State private var selectedTime: Date = {
        var c = DateComponents()
        c.hour = 21; c.minute = 0
        return Calendar.current.date(from: c) ?? Date()
    }()

    /// Total pages: Welcome, Accounts, Schedule, Calendar+Behavior, Launch
    private var totalPages: Int { 6 }

    /// Whether user can advance past the current page
    private var canAdvance: Bool {
        switch currentPage {
        case 0: return true                     // Welcome — always
        case 1: return appState.hasSources       // Accounts — need at least 1
        case 2: return true                     // Mode — always (has defaults)
        case 3: return true                     // Preferences — always optional
        case 4: return true                     // Behavior — always optional
        case 5: return true                     // Launch
        default: return true
        }
    }

    var body: some View {
        ZStack {
            IL.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    accountsPage.tag(1)
                    modePage.tag(2)
                    preferencesPage.tag(3)
                    behaviorPage.tag(4)
                    launchPage.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: currentPage)
                .onChange(of: currentPage) { newPage in
                    // Dismiss keyboard on page change
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

                    // Block swiping forward past accounts page if no source connected
                    if newPage > 1 && !appState.hasSources {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            currentPage = 1
                        }
                    }
                }

                // Bottom: progress dots + next button
                bottomBar
                    .padding(.horizontal, IL.pagePadding)
                    .padding(.bottom, 40)
                    .opacity(currentPage < totalPages - 1 ? 1 : 0)
                    .allowsHitTesting(currentPage < totalPages - 1)
            }
        }
        .onAppear {
            var c = DateComponents()
            c.hour = appState.notificationHour
            c.minute = appState.notificationMinute
            if let d = Calendar.current.date(from: c) { selectedTime = d }
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { visible = true }
        }
        .sheet(isPresented: $showIMessageSetup) {
            iMessageSetupView()
        }
    }

    // MARK: - Bottom Bar (dots + next)

    private var bottomBar: some View {
        HStack {
            // Back button — hidden on first page
            if currentPage > 0 {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        currentPage = max(currentPage - 1, 0)
                    }
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(IL.paperInkFaint)
                        .padding(10)
                }
            }

            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Capsule()
                        .fill(i == currentPage ? IL.ink : IL.ink.opacity(0.15))
                        .frame(width: i == currentPage ? 20 : 6, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                }
            }

            Spacer()

            // Next button
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    currentPage = min(currentPage + 1, totalPages - 1)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentPage == 0 ? "Begin" : "Next")
                        .font(IL.serif(15, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(canAdvance ? IL.paper : IL.paperInkFaint)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(canAdvance ? IL.paperInk : IL.paperInk.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            }
            .disabled(!canAdvance)
        }
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                // Elegant copper boomerang icon
                Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                    .font(.system(size: 38, weight: .ultraLight))
                    .foregroundColor(IL.accent)
                    .padding(.bottom, 28)
                    .opacity(visible ? 1 : 0)
                    .scaleEffect(visible ? 1 : 0.8)

                // App name — large, confident
                Text("Sweep")
                    .font(IL.serif(IL.isCompact ? 48 : 56, weight: .regular))
                    .foregroundColor(IL.paperInk)
                    .padding(.bottom, 6)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 12)

                // Thin copper accent line
                Rectangle().fill(IL.accent.opacity(0.5))
                    .frame(width: 40, height: 1)
                    .padding(.bottom, 20)
                    .opacity(visible ? 1 : 0)

                // Tagline
                Text("Reply to what matters.\nIgnore what doesn't.")
                    .font(IL.serif(18)).italic()
                    .foregroundColor(IL.paperInk.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 8)
            }

            Spacer().frame(height: 50)

            // Feature highlights — three elegant pills
            VStack(spacing: 12) {
                featurePill(icon: "sparkles", text: "AI drafts your replies")
                featurePill(icon: "hand.draw", text: "Swipe right to send, left to dismiss")
                featurePill(icon: "clock.arrow.circlepath", text: "Clear your inbox in minutes")
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 16)

            Spacer()

            // Bottom flourish
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Rectangle().fill(IL.paperInk.opacity(0.2)).frame(height: 0.5)
                    Rectangle().fill(IL.paperInk.opacity(0.2)).frame(height: 1)
                }
                .frame(width: 60)

                Text("Your inbox, finally under control.")
                    .font(IL.serif(12)).italic()
                    .foregroundColor(IL.paperInkFaint)
            }
            .opacity(visible ? 1 : 0)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, IL.pagePadding)
    }

    private func featurePill(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IL.accent)
                .frame(width: 20)
            Text(text)
                .font(IL.serif(13))
                .foregroundColor(IL.paperInk.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(IL.paperInk.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: IL.radius + 2))
    }

    // MARK: - Page 1: Connect Accounts

    private var accountsPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                pageHeader(
                    number: "I",
                    title: "Connect your sources",
                    subtitle: "Sweep will scan these accounts for correspondence that needs your attention."
                )

                Spacer().frame(height: 28)

                // Connected accounts
                if !appState.accounts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(appState.accounts.enumerated()), id: \.element.id) { idx, account in
                            if idx > 0 {
                                Rectangle().fill(IL.paperRule).frame(height: 0.5).padding(.leading, 48)
                            }
                            HStack(spacing: 12) {
                                ServiceIcon(service: account.service, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.identifier)
                                        .font(IL.serif(15)).foregroundColor(IL.ink)
                                        .lineLimit(1)
                                    Text(account.service.label)
                                        .font(IL.serif(12)).foregroundColor(IL.inkFaint)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color(red: 0.30, green: 0.60, blue: 0.35))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .background(IL.card)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                    .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))
                    .padding(.bottom, 16)
                }

                if let error = errorMessage {
                    Text(error).font(IL.serif(14)).italic()
                        .foregroundColor(IL.accent)
                        .padding(.bottom, 8)
                }

                Text(appState.accounts.isEmpty ? "Connect at least one to continue" : "Add another source")
                    .font(IL.serif(13)).italic()
                    .foregroundColor(appState.accounts.isEmpty ? IL.accent : IL.paperInkFaint)
                    .padding(.bottom, 14)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    serviceButton(.gmail)
                    serviceButton(.outlook)

                    // iMessage — opens setup sheet
                    Button { showIMessageSetup = true } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                // Apple Messages-style icon
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.35, green: 0.85, blue: 0.40),
                                                Color(red: 0.20, green: 0.72, blue: 0.30)
                                            ],
                                            startPoint: .top, endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 36, height: 36)
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white)

                                if appState.imessageRelayConnected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(IL.imessageGreen)
                                        .background(Circle().fill(IL.card).frame(width: 16, height: 16))
                                        .offset(x: 14, y: 14)
                                }
                            }
                            Text("iMessage")
                                .font(IL.serif(14))
                                .foregroundColor(IL.ink)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                        .background(IL.card)
                        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                        .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(appState.imessageRelayConnected ? IL.imessageGreen.opacity(0.4) : IL.ruleOnCard, lineWidth: appState.imessageRelayConnected ? 1 : 0.5))
                    }

                    serviceButton(.teams)
                    serviceButton(.slack)
                    serviceButton(.groupme)
                }

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, IL.pagePadding)
        }
    }

    // MARK: - Page 2: How It Works

    private var modePage: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                pageHeader(
                    number: "II",
                    title: "Choose your style",
                    subtitle: "How should Sweep fit into your day?"
                )

                Spacer().frame(height: 28)

                VStack(spacing: 12) {
                    // Stack mode card
                    modeCard(
                        mode: .stack,
                        icon: "square.stack.3d.up",
                        headline: "Smart Stack",
                        description: "Your sweep is always ready. Sweep watches silently and notifies you when a batch worth 10–15 minutes has built up. Clear it whenever you want.",
                        recommended: true
                    )

                    // Window mode card
                    modeCard(
                        mode: .window,
                        icon: "clock",
                        headline: "Evening Window",
                        description: "Sweep opens for one hour at a set time each day. Forced focus — when the window closes, email is done."
                    )
                }

                // Window time picker — always rendered to avoid slow wheel init,
                // but only visible when window mode selected
                VStack(spacing: 12) {
                    Rectangle().fill(IL.rule).frame(width: 40, height: 0.5)
                        .padding(.top, 16)

                    Text("Sweep opens at")
                        .font(IL.serif(13)).italic()
                        .foregroundColor(IL.paperInkFaint)

                    DatePicker("", selection: $selectedTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(height: 100)
                        .clipped()
                        .onChange(of: selectedTime) { newValue in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            if let h = c.hour, let m = c.minute {
                                appState.notificationHour = h
                                appState.notificationMinute = m
                                appState.saveSchedule()
                            }
                        }
                }
                .frame(height: appState.ledgerMode == .window ? nil : 0)
                .opacity(appState.ledgerMode == .window ? 1 : 0)
                .clipped()

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, IL.pagePadding)
            .animation(.easeInOut(duration: 0.3), value: appState.ledgerMode)
        }
    }

    private func modeCard(mode: LedgerMode, icon: String, headline: String, description: String, recommended: Bool = false) -> some View {
        let isSelected = appState.ledgerMode == mode

        return Button {
            // During onboarding, set mode directly (no rate limit, no fetch)
            print("🎨 Onboarding mode tap: \(mode.rawValue) (current: \(appState.ledgerMode.rawValue), onboarded: \(appState.hasCompletedOnboarding))")
            appState.ledgerMode = mode
            appState.saveMode()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? IL.ink : IL.inkFaint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(headline)
                                .font(IL.serif(15, weight: .medium))
                                .foregroundColor(isSelected ? IL.ink : IL.inkFaint)
                            if recommended {
                                Text("Recommended")
                                    .font(IL.serif(9, weight: .medium))
                                    .foregroundColor(IL.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(IL.accent, lineWidth: 0.5)
                                    )
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? Color(red: 0.30, green: 0.60, blue: 0.35) : IL.inkFaint)
                }

                Text(description)
                    .font(IL.serif(12))
                    .foregroundColor(isSelected ? IL.inkLight : IL.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .padding(.leading, 40)
            }
            .padding(16)
            .background(IL.card)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .overlay(
                RoundedRectangle(cornerRadius: IL.radius)
                    .stroke(isSelected ? IL.ink : IL.rule, lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func onboardingSensitivityLabel(_ level: Int) -> String {
        switch level {
        case 1:  return "Fewer"
        case 3:  return "More"
        default: return "Balanced"
        }
    }

    private func onboardingSensitivityHint(_ level: Int) -> String {
        switch level {
        case 1:  return "~1× per day. Only when several important emails build up."
        case 3:  return "2–3× per day. Even a couple of must-reply emails trigger a nudge."
        default: return "1–2× per day. A good balance."
        }
    }

    private func onboardingSnoozeLabel(_ hours: Int) -> String {
        switch hours {
        case 3:  return "3h"
        case 6:  return "6h"
        case 12: return "12h"
        case 24: return "1 day"
        default: return "\(hours)h"
        }
    }

    private func onboardingSnoozeHint(_ hours: Int) -> String {
        switch hours {
        case 3:  return "Snoozed cards reappear after 3 hours."
        case 6:  return "Snoozed cards reappear after 6 hours."
        case 12: return "Snoozed cards reappear after half a day."
        case 24: return "Snoozed cards reappear tomorrow."
        default: return "Snoozed cards reappear after \(hours) hours."
        }
    }

    // MARK: - Page 3: Preferences (Calendar + Sign-off)

    private var preferencesPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                pageHeader(
                    number: "III",
                    title: "Preferences",
                    subtitle: "Optional — you can change these later in Settings."
                )

                Spacer().frame(height: 32)

                VStack(spacing: 14) {
                    // Calendar explanation
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            Image(systemName: "calendar")
                                .font(.system(size: 22))
                                .foregroundColor(IL.ink)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Calendar-aware replies")
                                    .font(IL.serif(15, weight: .medium)).foregroundColor(IL.ink)
                                Text("When an email mentions scheduling, drafts will suggest times you're actually free.")
                                    .font(IL.serif(12)).foregroundColor(IL.inkFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Rectangle().fill(IL.ruleOnCard).frame(height: 0.5)
                            .padding(.leading, 46)

                        // Google / Outlook — auto
                        if appState.accounts.contains(where: { $0.service == .gmail || $0.service == .outlook }) {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(red: 0.30, green: 0.60, blue: 0.35))
                                let names = [
                                    appState.accounts.contains(where: { $0.service == .gmail }) ? "Google Calendar" : nil,
                                    appState.accounts.contains(where: { $0.service == .outlook }) ? "Outlook Calendar" : nil
                                ].compactMap { $0 }.joined(separator: " & ")
                                Text("\(names) linked automatically")
                                    .font(IL.serif(12)).foregroundColor(IL.paperInkLight)
                            }
                            .padding(.leading, 46)
                        }

                        // iCloud — needs permission
                        HStack(spacing: 10) {
                            Image(systemName: calendarGranted ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14))
                                .foregroundColor(calendarGranted
                                    ? Color(red: 0.30, green: 0.60, blue: 0.35) : IL.inkFaint)

                            Text(calendarGranted ? "iCloud Calendar connected" : "iCloud Calendar")
                                .font(IL.serif(12)).foregroundColor(IL.paperInkLight)

                            Spacer()

                            if !calendarGranted {
                                Button {
                                    Task {
                                        let granted = await CalendarManager.shared.requestAccess()
                                        withAnimation(.easeInOut(duration: 0.2)) { calendarGranted = granted }
                                    }
                                } label: {
                                    Text("Allow")
                                        .font(IL.serif(11, weight: .medium))
                                        .foregroundColor(IL.paper)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(IL.paperInk)
                                        .cornerRadius(IL.radius)
                                }
                            }
                        }
                        .padding(.leading, 46)

                        if !calendarGranted && !appState.accounts.contains(where: { $0.service == .gmail || $0.service == .outlook }) {
                            Text("Optional — you can skip this step.")
                                .font(IL.serif(10)).italic().foregroundColor(IL.inkFaint)
                                .padding(.leading, 46)
                        }
                    }
                    .padding(16)
                    .background(IL.card)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                    .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))

                    // Sign-off
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            Image(systemName: "signature")
                                .font(.system(size: 20))
                                .foregroundColor(IL.ink)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sign-off name")
                                    .font(IL.serif(15, weight: .medium)).foregroundColor(IL.ink)
                                Text("Added above your email signature in every reply.")
                                    .font(IL.serif(12)).foregroundColor(IL.inkFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Toggle("", isOn: $appState.appendLedgerSignature)
                                .labelsHidden()
                                .tint(Color(red: 0.30, green: 0.60, blue: 0.35))
                                .onChange(of: appState.appendLedgerSignature) { _ in
                                    appState.saveSignature()
                                }
                        }

                        if appState.appendLedgerSignature {
                            Rectangle().fill(IL.rule).frame(height: 0.5)
                                .padding(.leading, 46)

                            HStack(spacing: 10) {
                                Spacer().frame(width: 36)
                                TextField("e.g. Adnan", text: $appState.emailSignature)
                                    .font(IL.serif(14))
                                    .foregroundColor(IL.ink)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.words)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    }
                                    .toolbar {
                                        ToolbarItemGroup(placement: .keyboard) {
                                            Spacer()
                                            Button("Done") {
                                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                            }
                                            .font(IL.serif(14, weight: .medium))
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(IL.cardAlt)
                                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                                    .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))
                                    .onChange(of: appState.emailSignature) { _ in
                                        appState.saveSignature()
                                    }
                            }

                            Text("Your email provider's signature is always included separately.")
                                .font(IL.serif(10)).italic()
                                .foregroundColor(IL.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 46)
                        }
                    }
                    .padding(16)
                    .background(IL.card)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                    .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))
                }

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, IL.pagePadding)
        }
    }

    // MARK: - Page 4: Behavior (Mark as read + Notification frequency)

    private var behaviorPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                pageHeader(
                    number: "IV",
                    title: "Behavior",
                    subtitle: "Fine-tune how Sweep handles your replies."
                )

                Spacer().frame(height: 32)

                VStack(spacing: 14) {
                    // Mark as read
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            Image(systemName: "envelope.open")
                                .font(.system(size: 20))
                                .foregroundColor(IL.ink)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Mark as read after reply")
                                    .font(IL.serif(15, weight: .medium)).foregroundColor(IL.ink)
                                Text("The original email is marked as read in your inbox after you reply.")
                                    .font(IL.serif(12)).foregroundColor(IL.inkFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Toggle("", isOn: $appState.markAsReadAfterReply)
                                .labelsHidden()
                                .tint(Color(red: 0.30, green: 0.60, blue: 0.35))
                                .onChange(of: appState.markAsReadAfterReply) { _ in
                                    appState.saveMarkAsReadSetting()
                                }
                        }
                    }
                    .padding(16)
                    .background(IL.card)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                    .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))

                    // Notification frequency — stack mode only
                    if appState.ledgerMode == .stack {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                Image(systemName: "bell.badge")
                                    .font(.system(size: 20))
                                    .foregroundColor(IL.ink)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Notification frequency")
                                        .font(IL.serif(15, weight: .medium)).foregroundColor(IL.ink)
                                    Text("How often Sweep nudges you when a batch of replies is ready.")
                                        .font(IL.serif(12)).foregroundColor(IL.inkFaint)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Rectangle().fill(IL.rule).frame(height: 0.5)
                                .padding(.leading, 46)

                            HStack(spacing: 0) {
                                ForEach([1, 2, 3], id: \.self) { level in
                                    Button {
                                        appState.batchSensitivity = level
                                        appState.saveBatchSensitivity()
                                    } label: {
                                        VStack(spacing: 4) {
                                            Text(onboardingSensitivityLabel(level))
                                                .font(IL.serif(13, weight: appState.batchSensitivity == level ? .medium : .regular))
                                                .foregroundColor(appState.batchSensitivity == level ? IL.ink : IL.inkFaint)
                                            Rectangle()
                                                .fill(appState.batchSensitivity == level ? IL.ink : Color.clear)
                                                .frame(height: 1.5)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 46)

                            Text(onboardingSensitivityHint(appState.batchSensitivity))
                                .font(IL.serif(11)).italic()
                                .foregroundColor(IL.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 46)
                        }
                        .padding(16)
                        .background(IL.card)
                        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                        .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))
                        .animation(.easeInOut(duration: 0.2), value: appState.batchSensitivity)
                    }

                    // Snooze duration
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            Image(systemName: "moon.zzz")
                                .font(.system(size: 20))
                                .foregroundColor(IL.ink)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Snooze duration")
                                    .font(IL.serif(15, weight: .medium)).foregroundColor(IL.ink)
                                Text("When you swipe down on a card, how long should it disappear?")
                                    .font(IL.serif(12)).foregroundColor(IL.inkFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Rectangle().fill(IL.ruleOnCard).frame(height: 0.5)
                            .padding(.leading, 46)

                        HStack(spacing: 6) {
                            ForEach([3, 6, 12, 24], id: \.self) { hours in
                                Button {
                                    appState.snoozeHours = hours
                                    appState.saveSnoozeHours()
                                } label: {
                                    Text(onboardingSnoozeLabel(hours))
                                        .font(IL.serif(13, weight: appState.snoozeHours == hours ? .medium : .regular))
                                        .foregroundColor(appState.snoozeHours == hours ? IL.card : IL.ink)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(appState.snoozeHours == hours ? IL.ink : IL.ink.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 46)

                        Text(onboardingSnoozeHint(appState.snoozeHours))
                            .font(IL.serif(11)).italic()
                            .foregroundColor(IL.paperInkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 46)
                    }
                    .padding(16)
                    .background(IL.card)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                    .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))
                    .animation(.easeInOut(duration: 0.2), value: appState.snoozeHours)
                }

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, IL.pagePadding)
        }
    }

    // MARK: - Page 5: Launch

    private var launchPage: some View {
        VStack(spacing: 0) {
            Spacer()

            // Newspaper double rule
            VStack(spacing: 2) {
                Rectangle().fill(IL.paperInk).frame(height: 1.5)
                Rectangle().fill(IL.paperInk).frame(height: 0.5)
            }
            .frame(width: 120)
            .padding(.bottom, 24)

            Text("Ready.")
                .font(IL.serif(36, weight: .regular))
                .foregroundColor(IL.paperInk)
                .padding(.bottom, 8)

            Text("Your sweep awaits.")
                .font(IL.serif(16)).italic()
                .foregroundColor(IL.paperInkFaint)
                .padding(.bottom, 6)

            Text("Swipe right or tap to begin")
                .font(IL.serif(12)).italic()
                .foregroundColor(IL.paperInkFaint.opacity(0.6))
                .padding(.bottom, 34)

            Button {
                withAnimation(.easeInOut(duration: 0.5)) {
                    appState.completeOnboarding()
                }
            } label: {
                Text("Open Sweep \u{2192}")
                    .font(IL.serif(18, weight: .medium)).tracking(0.3)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .foregroundColor(IL.paper)
                    .background(IL.paperInk)
                    .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            }
            .padding(.horizontal, IL.pagePadding)

            Spacer()

            VStack(spacing: 2) {
                Rectangle().fill(IL.paperInk).frame(height: 0.5)
                Rectangle().fill(IL.paperInk).frame(height: 1.5)
            }
            .frame(width: 120)
            .padding(.bottom, 20)

            // Back button
            Button {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    currentPage = max(currentPage - 1, 0)
                }
            } label: {
                Text("\u{2190} Back")
                    .font(IL.serif(14)).foregroundColor(IL.paperInkFaint)
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, IL.pagePadding)
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    // Swipe right (positive horizontal, mostly horizontal)
                    if value.translation.width > 80 && abs(value.translation.height) < abs(value.translation.width) {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            appState.completeOnboarding()
                        }
                    }
                }
        )
    }

    // MARK: - Page Header

    private func pageHeader(number: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Text(number)
                .font(IL.serif(12)).italic()
                .foregroundColor(IL.paperInkFaint)
                .padding(.bottom, 8)

            Rectangle().fill(IL.paperRule).frame(width: 30, height: 0.5)
                .padding(.bottom, 16)

            Text(title)
                .font(IL.serif(28, weight: .regular))
                .foregroundColor(IL.paperInk)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 10)

            Text(subtitle)
                .font(IL.serif(14)).italic()
                .foregroundColor(IL.paperInkFaint)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Service Button

    private func serviceButton(_ service: AccountService) -> some View {
        Button { connect(service) } label: {
            VStack(spacing: 8) {
                if connecting == service {
                    ProgressView().tint(serviceColor(service)).scaleEffect(0.8)
                        .frame(width: 36, height: 36)
                } else {
                    ServiceIcon(service: service, size: 36)
                }
                Text(service.label)
                    .font(IL.serif(14))
                    .foregroundColor(IL.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(IL.card)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard, lineWidth: 0.5))
        }
        .disabled(connecting != nil)
    }

    private func connect(_ service: AccountService) {
        connecting = service; errorMessage = nil
        Task {
            let before = appState.accounts.count
            switch service {
            case .gmail:    await appState.addGmailAccount()
            case .outlook:  await appState.addOutlookAccount()
            case .teams:    await appState.addTeamsAccount()
            case .slack:    await appState.addSlackAccount()
            case .telegram: await appState.addTelegramAccount()
            case .groupme:  await appState.addGroupMeAccount()
            }
            if appState.accounts.count == before {
                withAnimation { errorMessage = "Unable to connect \(service.label)." }
            }
            connecting = nil
        }
    }

    private func serviceColor(_ service: AccountService) -> Color {
        switch service {
        case .gmail:    return IL.accent
        case .outlook:  return IL.outlookBlue
        case .teams:    return IL.teamsPurple
        case .slack:    return IL.slackPurple
        case .telegram: return IL.telegramBlue
        case .groupme:  return IL.groupmeTeal
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environmentObject(AppState())
    }
}
#endif


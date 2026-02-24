// SettingsView.swift
// Ledger

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var subscription = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTime = Date()
    @State private var notificationsEnabled = true
    @State private var isConnecting: AccountService? = nil
    @State private var accountToRemove: ConnectedAccount? = nil
    @State private var calendarEnabled = CalendarManager.shared.isEnabled
    @State private var showResetStyleConfirm = false
    @State private var showModeSwitchConfirm = false
    @State private var showModeSwitchBlocked = false
    @State private var pendingModeSwitch: LedgerMode? = nil
    @State private var showIMessageSetup = false

    private var calendarSourceDescription: String {
        var sources: [String] = []
        if CalendarManager.shared.isAuthorized { sources.append("iCloud") }
        if CalendarManager.shared.hasGoogleCalendarAccounts { sources.append("Google") }
        if CalendarManager.shared.hasOutlookCalendarAccounts { sources.append("Outlook") }
        let joined = sources.isEmpty ? "your calendar" : sources.joined(separator: " + ")
        return "Reading from \(joined). Drafts reference your availability when emails mention scheduling."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IL.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        sourcesSection
                        modeSection
                        signOffSection
                        styleMemorySection
                        calendarSection
                        behaviorSection
                        subscriptionSection
                        colophonSection
                    }
                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings").font(IL.serif(16)).italic().foregroundColor(IL.paperInkLight)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done").font(IL.serif(15, weight: .medium)).foregroundColor(IL.accent)
                    }
                }
            }
            .confirmationDialog(
                "Remove \(accountToRemove?.identifier ?? "account")?",
                isPresented: Binding(
                    get: { accountToRemove != nil },
                    set: { if !$0 { accountToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let account = accountToRemove {
                        appState.removeAccount(account)
                        if !appState.isReady { dismiss() }
                    }
                    accountToRemove = nil
                }
                Button("Cancel", role: .cancel) { accountToRemove = nil }
            }
            .onAppear {
                var c = DateComponents()
                c.hour = appState.notificationHour
                c.minute = appState.notificationMinute
                selectedTime = Calendar.current.date(from: c) ?? Date()
            }
            .alert("Switch mode?", isPresented: $showModeSwitchConfirm) {
                Button("Switch", role: .destructive) {
                    if let mode = pendingModeSwitch {
                        appState.switchMode(to: mode)
                    }
                    pendingModeSwitch = nil
                }
                Button("Cancel", role: .cancel) { pendingModeSwitch = nil }
            } message: {
                if let mode = pendingModeSwitch {
                    Text("Switch to \(mode.title)? Your current cards will be cleared and rebuilt. You can only switch modes once per day.")
                }
            }
            .alert("Mode switch unavailable", isPresented: $showModeSwitchBlocked) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("You've already switched modes today. Try again tomorrow.")
            }
            .sheet(isPresented: $showIMessageSetup) {
                iMessageSetupView()
                    .environmentObject(appState)
                    .onDisappear {
                        if appState.imessageRelayConnected {
                            appState.enableIMessage()
                        }
                    }
            }
        }
    }

    // MARK: - Sources Section

    private var sourcesSection: some View {
        section(title: "Sources") {
            serviceSection(service: .gmail, color: IL.accent, accounts: appState.accounts(for: .gmail))
            thinRule
            serviceSection(service: .outlook, color: IL.outlookBlue, accounts: appState.accounts(for: .outlook))
            thinRule
            serviceSection(service: .slack, color: IL.slackPurple, accounts: appState.accounts(for: .slack))
            thinRule
            serviceSection(service: .teams, color: IL.teamsPurple, accounts: appState.accounts(for: .teams))
            thinRule
            serviceSection(service: .groupme, color: IL.groupmeTeal, accounts: appState.accounts(for: .groupme))
            thinRule
            iMessageRow
        }
    }

    private var iMessageRow: some View {
        row {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(IL.imessageGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text("iMessage").font(IL.serif(15)).foregroundColor(IL.ink)
                    if appState.imessageRelayConnected, let mac = appState.imessageRelayMacName {
                        Text("via \(mac)")
                            .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                    } else if appState.imessageEnabled {
                        Text("Mac disconnected")
                            .font(IL.serif(11)).foregroundColor(.orange)
                    } else {
                        Text("Requires Mac companion app")
                            .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                    }
                }
                Spacer()

                if appState.imessageEnabled && appState.imessageRelayConnected {
                    Toggle("", isOn: Binding(
                        get: { appState.imessageEnabled },
                        set: { enabled in
                            if enabled { appState.enableIMessage() }
                            else { appState.disableIMessage() }
                        }
                    ))
                    .labelsHidden().tint(IL.imessageGreen)
                } else if appState.imessageEnabled && !appState.imessageRelayConnected {
                    HStack(spacing: 8) {
                        Button { showIMessageSetup = true } label: {
                            Text("Reconnect")
                                .font(IL.serif(12, weight: .medium))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Button { appState.disableIMessage() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(IL.inkFaint)
                        }
                    }
                } else {
                    Button { showIMessageSetup = true } label: {
                        Text("Set Up")
                            .font(IL.serif(12, weight: .medium))
                            .foregroundColor(IL.imessageGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(IL.imessageGreen.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - Mode Section

    private var modeSection: some View {
        section(title: "Mode") {
            row {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(LedgerMode.allCases, id: \.rawValue) { mode in
                        Button {
                            guard mode != appState.ledgerMode else { return }
                            if appState.hasUsedModeSwitchToday {
                                showModeSwitchBlocked = true
                            } else {
                                pendingModeSwitch = mode
                                showModeSwitchConfirm = true
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: appState.ledgerMode == mode ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(appState.ledgerMode == mode ? IL.accent : IL.inkFaint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.title)
                                        .font(IL.serif(13, weight: .medium))
                                        .foregroundColor(appState.ledgerMode == mode ? IL.ink : IL.inkFaint)
                                    Text(mode.subtitle)
                                        .font(IL.serif(10))
                                        .foregroundColor(IL.inkFaint)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if appState.ledgerMode == .window {
                thinRule
                row {
                    VStack(alignment: .leading, spacing: 4) {
                        DatePicker("Sweep opens at", selection: $selectedTime, displayedComponents: .hourAndMinute)
                            .font(IL.serif(15)).foregroundColor(IL.ink)
                            .onChange(of: selectedTime) { newValue in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                                if let h = c.hour, let m = c.minute {
                                    appState.notificationHour = h
                                    appState.notificationMinute = m
                                    appState.saveSchedule()
                                }
                            }
                        Text("You'll have one hour to clear your inbox.")
                            .font(IL.serif(11)).italic()
                            .foregroundColor(IL.inkFaint).padding(.top, 2)
                    }
                }
            }

            thinRule
            notificationsRow

            if appState.ledgerMode == .stack && notificationsEnabled {
                thinRule
                batchSensitivityRow
            }
        }
    }

    private var notificationsRow: some View {
        row {
            Toggle(isOn: $notificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push notifications").font(IL.serif(13)).foregroundColor(IL.ink)
                    Text(appState.ledgerMode == .stack
                        ? "Batch alerts based on priority, plus rare urgent alerts."
                        : "Reminder when your window opens.")
                        .font(IL.serif(10)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(IL.accent)
            .onChange(of: notificationsEnabled) { enabled in
                if !enabled {
                    NotificationManager.shared.cancelReminder()
                    NotificationManager.shared.cancelEveningReminder()
                }
            }
        }
    }

    private var batchSensitivityRow: some View {
        row {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notification frequency")
                    .font(IL.serif(13)).foregroundColor(IL.ink)
                HStack(spacing: 0) {
                    ForEach([1, 2, 3], id: \.self) { level in
                        Button {
                            appState.batchSensitivity = level
                            appState.saveBatchSensitivity()
                        } label: {
                            VStack(spacing: 4) {
                                Text(batchSensitivityLabel(level))
                                    .font(IL.serif(11, weight: appState.batchSensitivity == level ? .medium : .regular))
                                    .foregroundColor(appState.batchSensitivity == level ? IL.ink : IL.inkFaint)
                                Rectangle()
                                    .fill(appState.batchSensitivity == level ? IL.accent : Color.clear)
                                    .frame(height: 1.5)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(batchSensitivityDescription(appState.batchSensitivity))
                    .font(IL.serif(10)).italic()
                    .foregroundColor(IL.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sign-off Section

    private var signOffSection: some View {
        section(title: "Sign-off") {
            row {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Append name to replies")
                            .font(IL.serif(13)).foregroundColor(IL.ink)
                        Text("Adds your name above your email signature.")
                            .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                    }
                    Spacer()
                    Toggle("", isOn: $appState.appendLedgerSignature)
                        .labelsHidden()
                        .tint(IL.accent)
                        .onChange(of: appState.appendLedgerSignature) { _ in
                            appState.saveSignature()
                        }
                }
            }

            if appState.appendLedgerSignature {
                thinRule
                row {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("e.g. Adnan", text: $appState.emailSignature)
                            .font(IL.serif(14))
                            .foregroundColor(IL.ink)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                            .padding(12)
                            .background(IL.cardAlt)
                            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                            .overlay(
                                RoundedRectangle(cornerRadius: IL.radius)
                                    .stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5)
                            )
                            .onChange(of: appState.emailSignature) { _ in
                                appState.saveSignature()
                            }
                        Text("Your email provider's signature is always included separately.")
                            .font(IL.serif(10)).italic()
                            .foregroundColor(IL.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Style Memory Section

    private var styleMemorySection: some View {
        section(title: "Style Memory") {
            row {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Drafts adapt to your writing style")
                            .font(IL.serif(13)).foregroundColor(IL.ink)
                        Spacer()
                    }

                    let count = StyleMemory.shared.editedCount
                    if count < 3 {
                        Text("Send \(3 - count) more edited replies to activate learning.")
                            .font(IL.serif(11)).italic()
                            .foregroundColor(IL.inkFaint)
                    } else {
                        Text("Learning from \(count) edited replies. Drafts are personalized to your style.")
                            .font(IL.serif(11)).italic()
                            .foregroundColor(IL.accent)
                    }

                    if count > 0 {
                        Button { showResetStyleConfirm = true } label: {
                            Text("Reset")
                                .font(IL.serif(11)).italic()
                                .foregroundColor(IL.accent)
                        }
                        .alert("Reset style memory?", isPresented: $showResetStyleConfirm) {
                            Button("Cancel", role: .cancel) {}
                            Button("Reset", role: .destructive) { StyleMemory.shared.reset() }
                        } message: {
                            Text("Sweep will forget how you write — your tone, phrasing, and per-contact preferences. It will start learning again from scratch.")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Calendar Section

    private var calendarSection: some View {
        section(title: "Calendar") {
            row {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar-aware drafts")
                            .font(IL.serif(13)).foregroundColor(IL.ink)
                        Text(calendarEnabled
                            ? "Drafts reference your availability when emails mention scheduling."
                            : "Disabled. Drafts won't check your calendar.")
                            .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }
                    Spacer()
                    Toggle("", isOn: $calendarEnabled)
                        .labelsHidden()
                        .tint(IL.accent)
                        .onChange(of: calendarEnabled) { newValue in
                            CalendarManager.shared.isEnabled = newValue
                            appState.checkWindowConflict()
                        }
                }
            }

            if calendarEnabled {
                calendarProviderRows
            }
        }
    }

    @ViewBuilder
    private var calendarProviderRows: some View {
        Rectangle().fill(IL.rule).frame(height: 0.5)
        calendarProviderRow(
            name: "Google Calendar",
            isConnected: CalendarManager.shared.hasGoogleCalendarAccounts,
            connectedText: "Connected via your Gmail account.",
            disconnectedText: "Add a Gmail account above to connect."
        )
        Rectangle().fill(IL.rule).frame(height: 0.5)
        calendarProviderRow(
            name: "Outlook Calendar",
            isConnected: CalendarManager.shared.hasOutlookCalendarAccounts,
            connectedText: "Connected via your Outlook account.",
            disconnectedText: "Add an Outlook account above to connect."
        )
        Rectangle().fill(IL.rule).frame(height: 0.5)
        iCloudCalendarRow
    }

    private func calendarProviderRow(name: String, isConnected: Bool, connectedText: String, disconnectedText: String) -> some View {
        row {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(IL.serif(13)).foregroundColor(IL.ink)
                    Text(isConnected ? connectedText : disconnectedText)
                        .font(IL.serif(10)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isConnected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(IL.accent)
                }
            }
        }
    }

    private var iCloudCalendarRow: some View {
        row {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Calendar").font(IL.serif(13)).foregroundColor(IL.ink)
                    Text(CalendarManager.shared.isAuthorized
                        ? "Reading events from your device calendar."
                        : "Requires permission to read on-device calendars.")
                        .font(IL.serif(10)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if CalendarManager.shared.isAuthorized {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(IL.accent)
                } else {
                    Button {
                        Task {
                            let _ = await CalendarManager.shared.requestAccess()
                            appState.checkWindowConflict()
                        }
                    } label: {
                        Text("Allow")
                            .font(IL.serif(11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(IL.accent)
                            .cornerRadius(IL.radius)
                    }
                }
            }
        }
    }

    // MARK: - Behavior Section

    private var behaviorSection: some View {
        section(title: "Behavior") {
            markAsReadRow
            thinRule
            snoozeRow
            thinRule
            soundsRow
            thinRule
            hapticsRow
        }
    }

    private var markAsReadRow: some View {
        row {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mark as read after reply")
                        .font(IL.serif(13)).foregroundColor(IL.ink)
                    Text("When you reply through Sweep, the original email is marked as read in Gmail and Outlook.")
                        .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
                Spacer()
                Toggle("", isOn: $appState.markAsReadAfterReply)
                    .labelsHidden()
                    .tint(IL.accent)
                    .onChange(of: appState.markAsReadAfterReply) { _ in
                        appState.saveMarkAsReadSetting()
                    }
            }
        }
    }

    private var snoozeRow: some View {
        row {
            VStack(alignment: .leading, spacing: 8) {
                Text("Snooze duration")
                    .font(IL.serif(13)).foregroundColor(IL.ink)
                Text("How long to hold an email when you swipe down.")
                    .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach([3, 6, 12, 24], id: \.self) { hours in
                        Button {
                            appState.snoozeHours = hours
                            appState.saveSnoozeHours()
                        } label: {
                            Text(snoozeOptionLabel(hours))
                                .font(IL.serif(12, weight: appState.snoozeHours == hours ? .medium : .regular))
                                .foregroundColor(appState.snoozeHours == hours ? .white : IL.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(appState.snoozeHours == hours ? IL.accent : IL.cardAlt)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private var soundsRow: some View {
        row {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sounds").font(IL.serif(13)).foregroundColor(IL.ink)
                    Text("Subtle audio feedback when swiping cards.")
                        .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { SoundManager.shared.soundsEnabled },
                    set: { SoundManager.shared.soundsEnabled = $0 }
                ))
                .labelsHidden()
                .tint(IL.accent)
            }
        }
    }

    private var hapticsRow: some View {
        row {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Haptics").font(IL.serif(13)).foregroundColor(IL.ink)
                    Text("Vibration feedback paired with swipe actions.")
                        .font(IL.serif(11)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { SoundManager.shared.hapticsEnabled },
                    set: { SoundManager.shared.hapticsEnabled = $0 }
                ))
                .labelsHidden()
                .tint(IL.accent)
            }
        }
    }

    // MARK: - Subscription Section

    private var subscriptionSection: some View {
        section(title: "Subscription") {
            currentPlanRow
            thinRule
            tierComparisonRow
            thinRule
            testingTierRow
        }
    }

    private var currentPlanRow: some View {
        row {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(subscription.tierDisplayName)
                            .font(IL.serif(16, weight: .medium))
                            .foregroundColor(IL.ink)
                        if subscription.isTrialActive && subscription.tier == .free {
                            Text("\(subscription.trialDaysRemaining)d left")
                                .font(IL.serif(10, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(IL.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text("Your current plan")
                        .font(IL.serif(11))
                        .foregroundColor(IL.inkFaint)
                }
                Spacer()
            }
        }
    }

    private var tierComparisonRow: some View {
        row {
            VStack(alignment: .leading, spacing: 20) {
                tierCard(name: "Sweep Lite", price: "Free",
                    isCurrent: subscription.effectiveTier == .free,
                    features: [
                        ("5 cards per day", true), ("Quality AI-drafted replies", true),
                        ("Style learning", true), ("Unlimited redrafts", true),
                        ("Calendar-aware drafts", false), ("Batch notifications", false),
                        ("Per-contact voice", false), ("Near-frontier AI", false),
                    ])
                tierCard(name: "Sweep", price: "\(SubscriptionManager.standardMonthly)/mo",
                    isCurrent: subscription.effectiveTier == .standard,
                    features: [
                        ("Unlimited cards", true), ("Quality AI-drafted replies", true),
                        ("Style learning", true), ("Unlimited redrafts", true),
                        ("Calendar-aware drafts", true), ("Batch notifications", true),
                        ("Per-contact voice", false), ("Near-frontier AI", false),
                    ])
                tierCard(name: "Sweep Pro", price: "\(SubscriptionManager.proMonthly)/mo",
                    isCurrent: subscription.effectiveTier == .pro,
                    features: [
                        ("Unlimited cards", true), ("Near-frontier AI blend", true),
                        ("Style learning", true), ("Unlimited redrafts", true),
                        ("Calendar-aware drafts", true), ("Batch notifications", true),
                        ("Per-contact voice", true), ("Cutting-edge draft escalation", true),
                    ], highlight: true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11)).foregroundColor(IL.inkFaint)
                        Text("What is per-contact voice?")
                            .font(IL.serif(11, weight: .medium)).foregroundColor(IL.ink)
                    }
                    Text("Sweep Pro learns how you write to each person individually. A reply to your manager sounds different from a reply to a college friend — Pro remembers that and adapts your drafts accordingly.")
                        .font(IL.serif(10)).foregroundColor(IL.inkFaint)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
                .padding(12)
                .background(IL.inkWhisper.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            }
        }
    }

    private var testingTierRow: some View {
        row {
            VStack(alignment: .leading, spacing: 8) {
                Text("Testing: switch plan")
                    .font(IL.serif(13)).foregroundColor(IL.inkFaint)
                Picker("", selection: Binding(
                    get: { subscription.tier },
                    set: { SubscriptionManager.shared.setTier($0) }
                )) {
                    Text("Lite").tag(SubscriptionTier.free)
                    Text("Standard").tag(SubscriptionTier.standard)
                    Text("Pro").tag(SubscriptionTier.pro)
                }
                .pickerStyle(.segmented)
                Button {
                    SubscriptionManager.shared.resetTrial()
                } label: {
                    Text("Reset trial")
                        .font(IL.serif(11)).foregroundColor(IL.inkFaint).underline()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Colophon Section

    private var colophonSection: some View {
        section(title: "Colophon") {
            colophonRow(label: "Version", value: "1.0.0")
            thinRule
            colophonRow(label: "Plan", value: subscription.tierDisplayName)
            thinRule
            colophonRow(label: "Intelligence", value: "Near-frontier blend")
        }
    }

    @ViewBuilder
    private func tierCard(name: String, price: String, isCurrent: Bool, features: [(String, Bool)], highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(IL.serif(14, weight: .medium))
                        .foregroundColor(IL.ink)
                    Text(price)
                        .font(IL.serif(11))
                        .foregroundColor(IL.inkFaint)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(IL.serif(9, weight: .medium))
                        .foregroundColor(highlight ? .white : IL.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(highlight ? IL.accent : IL.cardAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                    HStack(spacing: 8) {
                        Image(systemName: feature.1 ? "checkmark" : "minus")
                            .font(.system(size: 9, weight: feature.1 ? .semibold : .regular))
                            .foregroundColor(feature.1 ? IL.accent : IL.inkFaint.opacity(0.4))
                            .frame(width: 14)
                        Text(feature.0)
                            .font(IL.serif(11))
                            .foregroundColor(feature.1 ? IL.ink : IL.inkFaint)
                    }
                }
            }
        }
        .padding(14)
        .background(
            isCurrent
                ? (highlight ? IL.accent.opacity(0.04) : IL.inkWhisper.opacity(0.3))
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
        .overlay(
            RoundedRectangle(cornerRadius: IL.radius)
                .stroke(
                    isCurrent
                        ? (highlight ? IL.accent.opacity(0.3) : IL.rule.opacity(0.5))
                        : IL.rule.opacity(0.3),
                    lineWidth: isCurrent ? 1 : 0.5
                )
        )
    }

    // MARK: - Service Section (multi-account)

    @ViewBuilder
    private func serviceSection(service: AccountService, color: Color, accounts: [ConnectedAccount]) -> some View {
        // Show each connected account — every row looks the same
        ForEach(Array(accounts.enumerated()), id: \.element.id) { pair in
            let index = pair.offset
            let account = pair.element
            if index > 0 {
                Rectangle().fill(IL.rule.opacity(0.4)).frame(height: 0.5).padding(.leading, 52).padding(.trailing, 16)
            }
            row {
                HStack(spacing: 10) {
                    ServiceIcon(service: service, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.label).font(IL.serif(15)).foregroundColor(IL.ink)
                        Text(account.identifier).font(IL.serif(11))
                            .foregroundColor(IL.inkFaint)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { account.isEnabled },
                        set: { _ in appState.toggleAccount(account) }
                    ))
                    .labelsHidden().tint(color)
                    Button { accountToRemove = account } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16))
                            .foregroundColor(IL.inkFaint)
                    }
                }
            }
        }

        // "Add" button — text only, no icon
        if accounts.isEmpty {
            row {
                Button { connectAccount(service) } label: {
                    HStack(spacing: 8) {
                        ServiceIcon(service: service, size: 22)
                        if isConnecting == service {
                            ProgressView().tint(color).scaleEffect(0.7)
                        }
                        Text("Connect \(service.label)")
                            .font(IL.serif(13))
                    }
                    .foregroundColor(color)
                }
                .disabled(isConnecting != nil)
            }
        } else {
            row {
                Button { connectAccount(service) } label: {
                    HStack(spacing: 5) {
                        if isConnecting == service {
                            ProgressView().tint(color).scaleEffect(0.7)
                        } else {
                            Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        }
                        Text("Add another")
                            .font(IL.serif(13))
                    }
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity)
                }
                .disabled(isConnecting != nil)
            }
        }
    }

    // MARK: - Connect

    private func connectAccount(_ service: AccountService) {
        guard isConnecting == nil else { return }
        isConnecting = service
        Task {
            switch service {
            case .gmail:    await appState.addGmailAccount()
            case .outlook:  await appState.addOutlookAccount()
            case .teams:    await appState.addTeamsAccount()
            case .slack:    await appState.addSlackAccount()
            case .telegram: await appState.addTelegramAccount()
            case .groupme:  await appState.addGroupMeAccount()
            }
            isConnecting = nil
        }
    }

    // MARK: - Layout Helpers

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(IL.serif(12)).italic().foregroundColor(IL.paperInkFaint).padding(.bottom, 8)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 2).background(IL.card)
                .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.ruleOnCard.opacity(0.5), lineWidth: 0.5))
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var thinRule: some View {
        Rectangle().fill(IL.ruleOnCard).frame(height: 0.5).padding(.horizontal, 16)
    }

    private func colophonRow(label: String, value: String) -> some View {
        row {
            HStack {
                Text(label).font(IL.serif(14)).foregroundColor(IL.ink)
                Spacer()
                Text(value).font(IL.serif(13)).italic().foregroundColor(IL.inkFaint)
            }
        }
    }

    // MARK: - Batch Sensitivity Helpers

    private func batchSensitivityLabel(_ level: Int) -> String {
        switch level {
        case 1:  return "Fewer"
        case 3:  return "More"
        default: return "Balanced"
        }
    }

    private func batchSensitivityDescription(_ level: Int) -> String {
        switch level {
        case 1:  return "Notified ~1× per day. Only when several important emails accumulate."
        case 3:  return "Notified 2–3× per day. Even a couple of important emails trigger an alert."
        default: return "Notified 1–2× per day. A good balance of awareness and calm."
        }
    }

    private func snoozeOptionLabel(_ hours: Int) -> String {
        switch hours {
        case 3:  return "3h"
        case 6:  return "6h"
        case 12: return "12h"
        case 24: return "1 day"
        default: return "\(hours)h"
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environmentObject(AppState())
    }
}
#endif

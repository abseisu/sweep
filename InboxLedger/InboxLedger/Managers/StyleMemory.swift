// StyleMemory.swift
// Ledger
//
// Learns the user's writing style across three dimensions:
// 1. Global style — overall patterns (length, formality, greetings, sign-offs, avoided phrases)
// 2. Per-contact style — how you write to specific people (casual to friends, formal to professors)
// 3. Redraft learning — when you re-prompt, we learn what "casual" or "shorter" means to YOU
//
// The style profile is distilled into a compact prompt section that gets more accurate over time.

import Foundation

// MARK: - Data Models

struct StyleExample: Codable, Identifiable {
    let id: String
    let date: Date
    let senderName: String
    let senderEmail: String
    let subject: String
    let category: String
    let tone: String
    let aiDraft: String
    let userFinal: String
    let wasEdited: Bool
    let redraftInstruction: String?
    let contactId: String
}

struct StyleProfile: Codable {
    var lengthPreference: String = ""
    var formalityLevel: String = ""
    var preferredGreeting: String = ""
    var preferredSignOff: String = ""
    var avoidPhrases: [String] = []
    var voiceNotes: [String] = []
    var emojiUse: String = ""
    var lastUpdated: Date = Date()
}

struct ContactStyle: Codable {
    let contactId: String
    let contactName: String
    var formalityLevel: String = ""
    var lengthPreference: String = ""
    var toneNotes: [String] = []
    var exampleCount: Int = 0
}

struct RedraftPattern: Codable {
    let instruction: String
    let beforeLength: Int
    let afterLength: Int
    let beforeSample: String
    let afterSample: String
}

// MARK: - StyleMemory

final class StyleMemory {

    static let shared = StyleMemory()
    private init() { loadAll() }

    private let examplesKey = "ledger_style_examples"
    private let profileKey = "ledger_style_profile"
    private let contactsKey = "ledger_contact_styles"
    private let redraftKey = "ledger_redraft_patterns"
    private let prefsKey = "ledger_style_preferences"
    private let sendsKey = "ledger_total_sends"
    private let lastCheckInKey = "ledger_last_checkin"
    private let maxExamples = 50

    private(set) var examples: [StyleExample] = []
    private(set) var profile: StyleProfile = StyleProfile()
    private(set) var contactStyles: [String: ContactStyle] = [:]
    private(set) var redraftPatterns: [RedraftPattern] = []
    private(set) var preferences: [String: String] = [:]
    private(set) var totalSends: Int = 0
    private(set) var lastCheckInAt: Int = 0

    // MARK: - Record an Edit

    func recordEdit(email: LedgerEmail, aiDraft: String, userFinal: String, redraftInstruction: String? = nil) {
        let normalizedAI = aiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUser = userFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasEdited = normalizedAI != normalizedUser
        let contactId = normalizeContact(email.senderEmail)

        let example = StyleExample(
            id: UUID().uuidString,
            date: Date(),
            senderName: email.senderName,
            senderEmail: email.senderEmail,
            subject: email.subject,
            category: email.category ?? "work",
            tone: email.detectedTone ?? "formal",
            aiDraft: String(normalizedAI.prefix(600)),
            userFinal: String(normalizedUser.prefix(600)),
            wasEdited: wasEdited,
            redraftInstruction: redraftInstruction,
            contactId: contactId
        )

        examples.append(example)
        if examples.count > maxExamples {
            examples = Array(examples.suffix(maxExamples))
        }

        updateContactStyle(contactId: contactId, contactName: email.senderName, example: example)

        if examples.filter({ $0.wasEdited }).count % 5 == 0 {
            distillProfile()
        }

        saveAll()

        if wasEdited {
            print("\u{1f4dd} StyleMemory: recorded edit for \(email.senderName) (\(editedCount) edited examples)")
        } else {
            print("\u{2705} StyleMemory: user sent AI draft as-is (\(examples.count) total)")
        }
    }

    func recordRedraft(instruction: String, beforeDraft: String, afterDraft: String) {
        let pattern = RedraftPattern(
            instruction: instruction.lowercased().trimmingCharacters(in: .whitespaces),
            beforeLength: beforeDraft.count,
            afterLength: afterDraft.count,
            beforeSample: String(beforeDraft.prefix(200)),
            afterSample: String(afterDraft.prefix(200))
        )
        redraftPatterns.append(pattern)
        if redraftPatterns.count > 30 {
            redraftPatterns = Array(redraftPatterns.suffix(30))
        }
        saveRedrafts()
        print("\u{1f504} StyleMemory: learned redraft pattern for '\(instruction)'")
    }

    func recordSend() {
        totalSends += 1
        UserDefaults.standard.set(totalSends, forKey: sendsKey)
    }

    // MARK: - Generate Style Prompt

    func stylePromptSection() -> String? {
        let editedExamples = examples.filter { $0.wasEdited }
        guard editedExamples.count >= 2 else { return nil }

        var sections: [String] = []
        sections.append(profilePrompt())

        let recent = Array(editedExamples.suffix(5))
        var exampleBlock = "RECENT STYLE EXAMPLES (study these closely — match the user's voice, not the AI's):\n"
        for (i, ex) in recent.enumerated() {
            exampleBlock += """
            Example \(i + 1) [\(ex.category), to: \(ex.senderName)]:
            AI wrote: "\(ex.aiDraft.prefix(250))"
            User changed to: "\(ex.userFinal.prefix(250))"
            \(ex.redraftInstruction != nil ? "User instruction: \"\(ex.redraftInstruction!)\"" : "")

            """
        }
        sections.append(exampleBlock)

        if let redraftSection = redraftVocabularyPrompt() {
            sections.append(redraftSection)
        }

        return sections.joined(separator: "\n")
    }

    func contactStyleHint(for email: LedgerEmail) -> String? {
        let contactId = normalizeContact(email.senderEmail)
        guard let style = contactStyles[contactId], style.exampleCount >= 2 else { return nil }

        var hint = "CONTACT-SPECIFIC STYLE for \(style.contactName):\n"
        if !style.formalityLevel.isEmpty {
            hint += "- Formality with this person: \(style.formalityLevel)\n"
        }
        if !style.lengthPreference.isEmpty {
            hint += "- Length with this person: \(style.lengthPreference)\n"
        }
        for note in style.toneNotes.suffix(3) {
            hint += "- \(note)\n"
        }
        return hint
    }

    func preferencesPromptSection() -> String? {
        guard !preferences.isEmpty else { return nil }

        var lines: [String] = ["USER PREFERENCES (from direct feedback \u{2014} follow these strictly):"]

        if let tone = preferences["default_tone"] { lines.append("- Default tone: \(tone)") }
        if let length = preferences["reply_length"] { lines.append("- Reply length preference: \(length)") }
        if let greeting = preferences["greetings"] { lines.append("- Preferred greeting: \(greeting)") }
        if let signoff = preferences["signoffs"] { lines.append("- Preferred sign-off: \(signoff)") }
        if let emoji = preferences["emoji_use"] { lines.append("- Exclamation/emoji use: \(emoji)") }
        if let friend = preferences["friend_tone"] { lines.append("- With close friends: \(friend)") }
        if let work = preferences["work_tone"] { lines.append("- At work: \(work)") }
        if let accuracy = preferences["draft_accuracy"] {
            lines.append("- User feedback on drafts: \(accuracy) \u{2014} PRIORITIZE adjusting for this")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Profile Distillation

    private func distillProfile() {
        let edited = examples.filter { $0.wasEdited }
        guard !edited.isEmpty else { return }

        let aiLengths = edited.map { $0.aiDraft.count }
        let userLengths = edited.map { $0.userFinal.count }
        let avgAI = aiLengths.reduce(0, +) / max(1, aiLengths.count)
        let avgUser = userLengths.reduce(0, +) / max(1, userLengths.count)
        let ratio = Double(avgUser) / max(1.0, Double(avgAI))

        if ratio < 0.6 {
            profile.lengthPreference = "Very concise. User cuts replies to about \(Int(ratio * 100))% of AI suggestions. Write SHORT."
        } else if ratio < 0.85 {
            profile.lengthPreference = "Concise. User trims replies. Aim for \(Int(ratio * 100))% of your default length."
        } else if ratio > 1.3 {
            profile.lengthPreference = "Thorough. User adds detail. Write \(Int(ratio * 100))% of your default length."
        } else {
            profile.lengthPreference = "Similar length to AI suggestions."
        }

        var greetingCounts: [String: Int] = [:]
        for ex in edited {
            if let g = extractGreeting(ex.userFinal) { greetingCounts[g, default: 0] += 1 }
        }
        let noGreetingCount = edited.filter { extractGreeting($0.userFinal) == nil }.count
        if noGreetingCount > edited.count / 2 {
            profile.preferredGreeting = "Often skips greetings \u{2014} dives straight into content"
        } else if let top = greetingCounts.max(by: { $0.value < $1.value }) {
            profile.preferredGreeting = "\"\(top.key)\" (used \(top.value) times)"
        }

        var signOffCounts: [String: Int] = [:]
        for ex in edited {
            if let s = extractSignOff(ex.userFinal) { signOffCounts[s.lowercased(), default: 0] += 1 }
        }
        let noSignOffCount = edited.filter { extractSignOff($0.userFinal) == nil }.count
        if noSignOffCount > edited.count / 2 {
            profile.preferredSignOff = "Often skips sign-offs"
        } else if let top = signOffCounts.max(by: { $0.value < $1.value }) {
            profile.preferredSignOff = "\"\(top.key)\" (used \(top.value) times)"
        }

        let casualIndicators = ["hey", "yo", "haha", "lol", "!", "gonna", "wanna", "tbh", "nah", "yep", "nope", "omg", "btw"]
        let formalIndicators = ["dear", "sincerely", "regards", "respectfully", "pursuant", "kindly", "i would like to"]
        var casualScore = 0; var formalScore = 0
        for ex in edited {
            let lower = ex.userFinal.lowercased()
            casualScore += casualIndicators.filter { lower.contains($0) }.count
            formalScore += formalIndicators.filter { lower.contains($0) }.count
        }
        let total = max(1, casualScore + formalScore)
        let casualRatio = Double(casualScore) / Double(total)
        if casualRatio > 0.75 {
            profile.formalityLevel = "Very casual \u{2014} uses slang, contractions, exclamations freely"
        } else if casualRatio > 0.5 {
            profile.formalityLevel = "Casual-professional \u{2014} friendly and warm but not sloppy"
        } else if formalScore > casualScore {
            profile.formalityLevel = "Formal \u{2014} proper grammar, professional structure"
        } else {
            profile.formalityLevel = "Neutral \u{2014} adapts to context"
        }

        let aiPhrases = [
            "I hope this email finds you", "I hope this message finds you",
            "I wanted to reach out", "Please don't hesitate",
            "Looking forward to hearing from you", "I trust this",
            "At your earliest convenience", "Thank you for your email",
            "I appreciate you reaching out", "Please let me know if you have any questions",
            "Happy to discuss further", "Don't hesitate to reach out",
            "I hope you're doing well", "I wanted to follow up"
        ]
        var removedCounts: [String: Int] = [:]
        for ex in edited {
            for phrase in aiPhrases {
                if ex.aiDraft.lowercased().contains(phrase.lowercased()) &&
                   !ex.userFinal.lowercased().contains(phrase.lowercased()) {
                    removedCounts[phrase, default: 0] += 1
                }
            }
        }
        profile.avoidPhrases = removedCounts.filter { $0.value >= 2 }.map { $0.key }.sorted()

        var notes: [String] = []
        let contractionCount = edited.filter { $0.userFinal.contains("'") }.count
        if contractionCount > edited.count / 2 {
            notes.append("Uses contractions frequently (don't, I'm, can't, won't)")
        }

        let avgSentenceLen = edited.map { avgWordsPerSentence($0.userFinal) }.reduce(0.0, +) / Double(max(1, edited.count))
        if avgSentenceLen < 10 {
            notes.append("Writes in short, punchy sentences (avg ~\(Int(avgSentenceLen)) words)")
        } else if avgSentenceLen > 20 {
            notes.append("Writes in longer, detailed sentences (avg ~\(Int(avgSentenceLen)) words)")
        }

        let iStartCount = edited.flatMap { $0.userFinal.components(separatedBy: ". ") }
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("I ") }.count
        let totalSentences = max(1, edited.flatMap { $0.userFinal.components(separatedBy: ". ") }.count)
        if Double(iStartCount) / Double(totalSentences) > 0.3 {
            notes.append("Frequently starts sentences with 'I'")
        }

        let questionCount = edited.filter { $0.userFinal.contains("?") }.count
        if questionCount > edited.count * 2 / 3 {
            notes.append("Often asks questions in replies \u{2014} conversational style")
        }

        profile.voiceNotes = notes
        profile.lastUpdated = Date()
        saveProfile()
        print("\u{1f9e0} StyleMemory: distilled profile updated (\(edited.count) examples analyzed)")
    }

    private func profilePrompt() -> String {
        var lines: [String] = ["DISTILLED STYLE PROFILE (follow this closely \u{2014} this represents the user's actual voice):"]

        if !profile.lengthPreference.isEmpty { lines.append("- Length: \(profile.lengthPreference)") }
        if !profile.formalityLevel.isEmpty { lines.append("- Formality: \(profile.formalityLevel)") }
        if !profile.preferredGreeting.isEmpty { lines.append("- Greeting: \(profile.preferredGreeting)") }
        if !profile.preferredSignOff.isEmpty { lines.append("- Sign-off: \(profile.preferredSignOff)") }
        if !profile.avoidPhrases.isEmpty {
            lines.append("- NEVER USE these phrases (user always removes them): \(profile.avoidPhrases.joined(separator: "; "))")
        }
        for note in profile.voiceNotes { lines.append("- \(note)") }

        if lines.count <= 1 { return "" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Redraft Vocabulary

    private func redraftVocabularyPrompt() -> String? {
        guard !redraftPatterns.isEmpty else { return nil }

        var grouped: [String: [RedraftPattern]] = [:]
        for p in redraftPatterns {
            grouped[normalizeInstruction(p.instruction), default: []].append(p)
        }

        var lines: [String] = ["REDRAFT VOCABULARY (what this user means by common instructions):"]
        for (instruction, patterns) in grouped.sorted(by: { $0.value.count > $1.value.count }).prefix(5) {
            let avgBefore = patterns.map { $0.beforeLength }.reduce(0, +) / max(1, patterns.count)
            let avgAfter = patterns.map { $0.afterLength }.reduce(0, +) / max(1, patterns.count)
            var desc = "When user says \"\(instruction)\":"
            if avgAfter < avgBefore / 2 {
                desc += " they want DRAMATICALLY shorter (cut by \(100 - avgAfter * 100 / max(1, avgBefore))%)"
            } else if avgAfter < avgBefore {
                desc += " they want somewhat shorter"
            }
            if let last = patterns.last {
                desc += " \u{2014} Example: \"\(last.afterSample.prefix(100))\""
            }
            lines.append("- \(desc)")
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    private func normalizeInstruction(_ instruction: String) -> String {
        let lower = instruction.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("casual") || lower.contains("informal") { return "more casual" }
        if lower.contains("formal") || lower.contains("professional") { return "more formal" }
        if lower.contains("short") || lower.contains("brief") || lower.contains("concise") { return "shorter" }
        if lower.contains("long") || lower.contains("detail") || lower.contains("thorough") { return "longer" }
        if lower.contains("friend") || lower.contains("warm") { return "friendlier" }
        if lower.contains("direct") || lower.contains("blunt") { return "more direct" }
        return lower
    }

    // MARK: - Per-Contact Learning

    private func normalizeContact(_ email: String) -> String {
        email.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private func updateContactStyle(contactId: String, contactName: String, example: StyleExample) {
        var style = contactStyles[contactId] ?? ContactStyle(contactId: contactId, contactName: contactName)
        style.exampleCount += 1
        guard example.wasEdited else { contactStyles[contactId] = style; return }

        let lower = example.userFinal.lowercased()
        let casualMarkers = ["hey", "haha", "!", "lol", "yo", "gonna", "nah", "yep"]
        let formalMarkers = ["dear", "regards", "sincerely", "respectfully"]
        let casualHits = casualMarkers.filter { lower.contains($0) }.count
        let formalHits = formalMarkers.filter { lower.contains($0) }.count

        if casualHits > formalHits + 1 { style.formalityLevel = "casual" }
        else if formalHits > casualHits { style.formalityLevel = "formal" }
        else if style.formalityLevel.isEmpty { style.formalityLevel = "neutral" }

        let ratio = Double(example.userFinal.count) / max(1.0, Double(example.aiDraft.count))
        if ratio < 0.7 { style.lengthPreference = "short" }
        else if ratio > 1.2 { style.lengthPreference = "detailed" }

        contactStyles[contactId] = style
        saveContacts()
    }

    // MARK: - Text Helpers

    private func avgWordsPerSentence(_ text: String) -> Double {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return 0 }
        let totalWords = sentences.flatMap { $0.components(separatedBy: .whitespaces) }.count
        return Double(totalWords) / Double(sentences.count)
    }

    private func extractSignOff(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let candidates = ["best", "cheers", "thanks", "regards", "sincerely", "warmly", "take care",
                          "best regards", "kind regards", "warm regards", "many thanks", "thank you",
                          "all the best", "talk soon"]
        for line in lines.suffix(3).reversed() {
            let lower = line.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if candidates.contains(where: { lower.hasPrefix($0) }) { return line }
        }
        return nil
    }

    private func extractGreeting(_ text: String) -> String? {
        let firstLine = text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let lower = firstLine.lowercased()
        let greetings = ["hi ", "hey ", "hello ", "dear ", "good morning", "good afternoon", "good evening", "yo "]
        if greetings.contains(where: { lower.hasPrefix($0) }) {
            if let comma = firstLine.firstIndex(of: ",") {
                let words = String(firstLine[firstLine.startIndex..<comma]).components(separatedBy: " ")
                return words.first ?? firstLine
            }
            return String(firstLine.prefix(15))
        }
        return nil
    }

    var editedCount: Int { examples.filter { $0.wasEdited }.count }

    // MARK: - Check-In System

    struct CheckInQuestion {
        let id: String
        let question: String
        let options: [String]
    }

    private let checkInPool: [CheckInQuestion] = [
        CheckInQuestion(id: "default_tone", question: "How do you usually like your emails to sound?",
                        options: ["Casual & warm", "Professional but friendly", "Strictly formal", "Depends on who it is"]),
        CheckInQuestion(id: "reply_length", question: "How long are your typical replies?",
                        options: ["Short & sweet (1-2 lines)", "Medium (a paragraph)", "Thorough (detailed)", "Matches the sender"]),
        CheckInQuestion(id: "greetings", question: "How do you usually start emails?",
                        options: ["Hey [name]!", "Hi [name],", "Dear [name],", "No greeting, just dive in"]),
        CheckInQuestion(id: "signoffs", question: "How do you usually sign off?",
                        options: ["Best,", "Thanks,", "Cheers,", "No sign-off"]),
        CheckInQuestion(id: "emoji_use", question: "Do you use exclamation marks or emoji in emails?",
                        options: ["Yes, often!", "Sometimes, with friends", "Rarely", "Never"]),
        CheckInQuestion(id: "friend_tone", question: "When emailing close friends, you write more like...",
                        options: ["Texting \u{2014} super casual", "Friendly but still email-like", "Same as everyone else"]),
        CheckInQuestion(id: "work_tone", question: "At work, your emails tend to be...",
                        options: ["Warm & personable", "Efficient & direct", "Formal & polished", "Depends on seniority"]),
        CheckInQuestion(id: "draft_accuracy", question: "How are the AI drafts so far?",
                        options: ["Too formal", "Too casual", "About right", "Too long", "Too short"]),
    ]

    var shouldShowCheckIn: Bool {
        let sendsSinceLastCheckIn = totalSends - lastCheckInAt
        guard sendsSinceLastCheckIn >= 5 else { return false }
        guard nextCheckIn != nil else { return false }
        return true
    }

    var nextCheckIn: CheckInQuestion? {
        checkInPool.first { !preferences.keys.contains($0.id) }
    }

    func answerCheckIn(questionId: String, answer: String) {
        preferences[questionId] = answer
        lastCheckInAt = totalSends
        UserDefaults.standard.set(lastCheckInAt, forKey: lastCheckInKey)
        savePreferences()
        print("\u{1f9e0} StyleMemory check-in: \(questionId) \u{2192} \(answer)")
    }

    // MARK: - Reset

    func reset() {
        examples.removeAll(); profile = StyleProfile(); contactStyles.removeAll()
        redraftPatterns.removeAll(); preferences.removeAll(); totalSends = 0; lastCheckInAt = 0
        saveAll()
    }

    // MARK: - Persistence

    private func saveAll() { saveExamples(); saveProfile(); saveContacts(); saveRedrafts(); savePreferences() }

    private func saveExamples() {
        guard let data = try? JSONEncoder().encode(examples) else { return }
        UserDefaults.standard.set(data, forKey: examplesKey)
    }
    private func saveProfile() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }
    private func saveContacts() {
        guard let data = try? JSONEncoder().encode(contactStyles) else { return }
        UserDefaults.standard.set(data, forKey: contactsKey)
    }
    private func saveRedrafts() {
        guard let data = try? JSONEncoder().encode(redraftPatterns) else { return }
        UserDefaults.standard.set(data, forKey: redraftKey)
    }
    private func savePreferences() {
        UserDefaults.standard.set(preferences, forKey: prefsKey)
    }

    private func loadAll() {
        if let data = UserDefaults.standard.data(forKey: examplesKey),
           let decoded = try? JSONDecoder().decode([StyleExample].self, from: data) { examples = decoded }
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(StyleProfile.self, from: data) { profile = decoded }
        if let data = UserDefaults.standard.data(forKey: contactsKey),
           let decoded = try? JSONDecoder().decode([String: ContactStyle].self, from: data) { contactStyles = decoded }
        if let data = UserDefaults.standard.data(forKey: redraftKey),
           let decoded = try? JSONDecoder().decode([RedraftPattern].self, from: data) { redraftPatterns = decoded }
        preferences = (UserDefaults.standard.dictionary(forKey: prefsKey) as? [String: String]) ?? [:]
        totalSends = UserDefaults.standard.integer(forKey: sendsKey)
        lastCheckInAt = UserDefaults.standard.integer(forKey: lastCheckInKey)
        print("\u{1f9e0} StyleMemory: loaded \(examples.count) examples, \(contactStyles.count) contacts, \(redraftPatterns.count) redraft patterns")
    }
}

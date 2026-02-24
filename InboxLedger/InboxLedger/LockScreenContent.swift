// LockScreenContent.swift
// Ledger
//
// Content engine for the lock screen — daily quotes, reach-out nudges,
// and ambient floating ink particles.

import SwiftUI

// MARK: - Daily Quotes

struct DailyQuote {
    let text: String
    let author: String
}

struct QuoteEngine {
    static let quotes: [DailyQuote] = [
        // On correspondence & connection
        DailyQuote(text: "Letter writing is the only device for combining solitude with good company.", author: "Lord Byron"),
        DailyQuote(text: "A letter is a joy of Earth — it is denied the gods.", author: "Emily Dickinson"),
        DailyQuote(text: "To send a letter is a good way to go somewhere without moving anything but your heart.", author: "Phyllis Theroux"),
        DailyQuote(text: "The best time to answer a letter is the moment you receive it.", author: "Chinese Proverb"),
        DailyQuote(text: "In a world of emails and texts, a thoughtful reply is a small act of grace.", author: "Unknown"),
        DailyQuote(text: "Correspondence is the great field for the display of kindness.", author: "Samuel Johnson"),

        // On attention & intention
        DailyQuote(text: "The greatest gift you can give someone is your attention.", author: "Jim Rohn"),
        DailyQuote(text: "How we spend our days is, of course, how we spend our lives.", author: "Annie Dillard"),
        DailyQuote(text: "The art of being wise is knowing what to overlook.", author: "William James"),
        DailyQuote(text: "Do every act of your life as though it were the very last act of your life.", author: "Marcus Aurelius"),
        DailyQuote(text: "Attention is the rarest and purest form of generosity.", author: "Simone Weil"),
        DailyQuote(text: "Almost everything will work again if you unplug it for a few minutes. Including you.", author: "Anne Lamott"),
        DailyQuote(text: "The real question is not whether machines think but whether men do.", author: "B.F. Skinner"),

        // On patience & timing
        DailyQuote(text: "Nature does not hurry, yet everything is accomplished.", author: "Lao Tzu"),
        DailyQuote(text: "Wisely and slow. They stumble that run fast.", author: "Shakespeare"),
        DailyQuote(text: "Have patience with everything unresolved in your heart.", author: "Rainer Maria Rilke"),
        DailyQuote(text: "The two most powerful warriors are patience and time.", author: "Leo Tolstoy"),
        DailyQuote(text: "All good things to those who wait.", author: "Violet Fane"),
        DailyQuote(text: "You cannot find peace by avoiding life.", author: "Virginia Woolf"),

        // On brevity & clarity
        DailyQuote(text: "I would have written a shorter letter, but I did not have the time.", author: "Blaise Pascal"),
        DailyQuote(text: "The most valuable of all talents is never using two words when one will do.", author: "Thomas Jefferson"),
        DailyQuote(text: "Brevity is the soul of wit.", author: "Shakespeare"),
        DailyQuote(text: "Be sincere; be brief; be seated.", author: "Franklin D. Roosevelt"),
        DailyQuote(text: "One day I will find the right words, and they will be simple.", author: "Jack Kerouac"),

        // On relationships
        DailyQuote(text: "We are all travelers in the wilderness of this world, and the best we can find in our travels is an honest friend.", author: "Robert Louis Stevenson"),
        DailyQuote(text: "The meeting of two personalities is like the contact of two chemical substances; if there is any reaction, both are transformed.", author: "Carl Jung"),
        DailyQuote(text: "No road is long with good company.", author: "Turkish Proverb"),
        DailyQuote(text: "Life is partly what we make it, and partly what it is made by the friends we choose.", author: "Tennessee Williams"),
        DailyQuote(text: "The ornament of a house is the friends who frequent it.", author: "Ralph Waldo Emerson"),
        DailyQuote(text: "There is nothing I would not do for those who are really my friends.", author: "Jane Austen"),
    ]

    /// Returns a deterministic quote based on the day of the year
    static func todaysQuote() -> DailyQuote {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return quotes[day % quotes.count]
    }
}

// MARK: - Reach-Out Nudges

struct ReachOutNudge {
    let message: String
    let contactName: String?
}

struct NudgeEngine {
    /// Generate a nudge based on dismissed/replied contacts, or a generic one
    static func todaysNudge(recentContacts: [String]) -> ReachOutNudge {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let hour = Calendar.current.component(.hour, from: Date())

        // If we have recent contacts, suggest reaching out to one
        if !recentContacts.isEmpty {
            let contactIndex = (day + hour) % recentContacts.count
            let name = recentContacts[contactIndex]
            let firstName = name.components(separatedBy: " ").first ?? name

            let templates = [
                "It's been a while since you heard from \(firstName). A quick note goes a long way.",
                "Consider dropping \(firstName) a line today — even a sentence counts.",
                "\(firstName) might appreciate hearing from you. What would you say?",
                "When did you last write to \(firstName)? Today could be the day.",
                "A short message to \(firstName) could make their evening.",
                "Some connections need tending. \(firstName) might be one.",
                "You've been in touch with \(firstName) recently — keep the thread alive.",
                "Think of \(firstName). Is there something left unsaid?",
            ]
            let template = templates[(day + recentContacts.count) % templates.count]
            return ReachOutNudge(message: template, contactName: name)
        }

        // Generic nudges when no contact history
        let generic = [
            "Who haven't you written to in a while? Reach out today.",
            "The best messages are the ones people don't expect.",
            "Pick someone you've been meaning to reply to. Tonight's the night.",
            "A two-line message can carry more weight than you think.",
            "Someone in your life is waiting to hear from you. Who is it?",
            "The hardest part of writing back is starting. Just start.",
            "Correspondence is a habit. Build it one reply at a time.",
            "Who made you smile this week? Tell them.",
        ]
        return ReachOutNudge(message: generic[day % generic.count], contactName: nil)
    }
}

// MARK: - Floating Ink Particles

struct InkParticle: Identifiable {
    let id: Int
    var x: CGFloat
    var y: CGFloat
    let size: CGFloat
    let opacity: Double
    let speed: CGFloat      // vertical drift speed
    let wobble: CGFloat     // horizontal sway amplitude
    let phase: CGFloat      // animation phase offset
}

struct FloatingInkView: View {
    @State private var particles: [InkParticle] = []
    @State private var animationPhase: CGFloat = 0
    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for p in particles {
                    let wobbleX = sin(animationPhase * p.speed * 0.3 + p.phase) * p.wobble
                    let x = p.x + wobbleX
                    let y = p.y

                    let rect = CGRect(
                        x: x - p.size / 2,
                        y: y - p.size / 2,
                        width: p.size,
                        height: p.size
                    )
                    context.opacity = p.opacity
                    context.fill(
                        Circle().path(in: rect),
                        with: .color(IL.ink)
                    )
                }
            }
            .onAppear {
                particles = (0..<30).map { i in
                    InkParticle(
                        id: i,
                        x: CGFloat.random(in: 0...geo.size.width),
                        y: CGFloat.random(in: 0...geo.size.height),
                        size: CGFloat.random(in: 2.5...7),
                        opacity: Double.random(in: 0.08...0.22),
                        speed: CGFloat.random(in: 0.12...0.4),
                        wobble: CGFloat.random(in: 10...30),
                        phase: CGFloat.random(in: 0...(.pi * 2))
                    )
                }
            }
            .onReceive(timer) { _ in
                animationPhase += 1
                for i in 0..<particles.count {
                    particles[i].y -= particles[i].speed
                    // Reset particles that float off top
                    if particles[i].y < -10 {
                        particles[i].y = geo.size.height + 10
                        particles[i].x = CGFloat.random(in: 0...geo.size.width)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Date Line

struct DateLineView: View {
    var body: some View {
        Text(formattedDate)
            .font(IL.serif(11)).tracking(1.5)
            .foregroundColor(IL.inkFaint)
            .textCase(.uppercase)
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }
}

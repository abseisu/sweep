// AIResponse.swift
// Ledger

import Foundation

struct AIResponse: Codable {
    let summary: String
    let draftResponse: String
    let detectedTone: String
    let replyability: Int
    let category: String
    let suggestReplyAll: Bool?

    enum CodingKeys: String, CodingKey {
        case summary, draftResponse, detectedTone, replyability, category, suggestReplyAll
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let summary = try? container.decode(String.self, forKey: .summary),
           let draft = try? container.decode(String.self, forKey: .draftResponse) {
            self.summary = summary
            self.draftResponse = draft
            self.detectedTone = (try? container.decode(String.self, forKey: .detectedTone)) ?? "formal"
            self.replyability = (try? container.decode(Int.self, forKey: .replyability)) ?? 50
            self.category = (try? container.decode(String.self, forKey: .category)) ?? "work"
            self.suggestReplyAll = try? container.decode(Bool.self, forKey: .suggestReplyAll)
            return
        }
        let container = try decoder.container(keyedBy: SnakeCaseKeys.self)
        self.summary = (try? container.decode(String.self, forKey: .summary)) ?? "Unable to analyze."
        self.draftResponse = (try? container.decode(String.self, forKey: .draftResponse)) ?? "Thank you for your message."
        self.detectedTone = (try? container.decode(String.self, forKey: .detectedTone)) ?? "formal"
        self.replyability = (try? container.decode(Int.self, forKey: .replyability)) ?? 50
        self.category = (try? container.decode(String.self, forKey: .category)) ?? "work"
        self.suggestReplyAll = try? container.decode(Bool.self, forKey: .suggestReplyAll)
    }

    private enum SnakeCaseKeys: String, CodingKey {
        case summary
        case draftResponse = "draft_response"
        case detectedTone = "detected_tone"
        case replyability
        case category
        case suggestReplyAll = "suggest_reply_all"
    }

    init(summary: String, draftResponse: String, detectedTone: String, replyability: Int, category: String, suggestReplyAll: Bool?) {
        self.summary = summary
        self.draftResponse = draftResponse
        self.detectedTone = detectedTone
        self.replyability = replyability
        self.category = category
        self.suggestReplyAll = suggestReplyAll
    }
}

// MARK: - Provider Response Models

struct OpenAIChatResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String?
    }
}

struct AnthropicResponse: Codable {
    let content: [ContentBlock]

    struct ContentBlock: Codable {
        let type: String
        let text: String?
    }

    var text: String? {
        content.first(where: { $0.type == "text" })?.text
    }
}

struct GeminiResponse: Codable { // kept for decode safety but unused
    let candidates: [Candidate]?
    struct Candidate: Codable { let content: Content? }
    struct Content: Codable { let parts: [Part]? }
    struct Part: Codable { let text: String? }
    var text: String? { candidates?.first?.content?.parts?.first?.text }
}

// MARK: - AI Provider

enum AIProvider: String, Codable, CaseIterable {
    case openai = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var modelName: String {
        switch self {
        case .openai:    return "GPT-4o Mini"
        case .anthropic: return "Claude Haiku 4.5"
        }
    }
}

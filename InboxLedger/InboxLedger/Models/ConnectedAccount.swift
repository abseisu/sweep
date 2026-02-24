// ConnectedAccount.swift
// Ledger

import Foundation

/// A single connected account (Gmail, Outlook, Slack, or Telegram).
/// Multiple accounts per service are supported.
struct ConnectedAccount: Identifiable, Equatable, Codable {
    let id: String                  // Unique: email address, team+userId, bot token hash
    let service: AccountService
    let displayName: String         // "Alex Rivera" or workspace name
    let identifier: String          // email, team name, bot name
    var accessToken: String
    var isEnabled: Bool = true

    // Exclude accessToken from Codable — it's stored in Keychain, not UserDefaults
    enum CodingKeys: String, CodingKey {
        case id, service, displayName, identifier, isEnabled
    }

    init(id: String, service: AccountService, displayName: String, identifier: String, accessToken: String, isEnabled: Bool = true) {
        self.id = id
        self.service = service
        self.displayName = displayName
        self.identifier = identifier
        self.accessToken = accessToken
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        service = try container.decode(AccountService.self, forKey: .service)
        displayName = try container.decode(String.self, forKey: .displayName)
        identifier = try container.decode(String.self, forKey: .identifier)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // Load accessToken from Keychain
        accessToken = KeychainHelper.get("oauth_token_\(id)") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(service, forKey: .service)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(isEnabled, forKey: .isEnabled)
        // Save accessToken to Keychain
        if !accessToken.isEmpty {
            KeychainHelper.set(accessToken, forKey: "oauth_token_\(id)")
        }
    }

    static func == (lhs: ConnectedAccount, rhs: ConnectedAccount) -> Bool {
        lhs.id == rhs.id
    }

    var ledgerSource: LedgerSource {
        switch service {
        case .gmail:    return .gmail
        case .outlook:  return .outlook
        case .teams:    return .teams
        case .slack:    return .slack
        case .telegram: return .telegram
        case .groupme:  return .groupme
        }
    }
}

enum AccountService: String, Codable, CaseIterable {
    case gmail
    case outlook
    case teams
    case slack
    case telegram
    case groupme

    var label: String {
        switch self {
        case .gmail:    return "Gmail"
        case .outlook:  return "Outlook"
        case .teams:    return "Teams"
        case .slack:    return "Slack"
        case .telegram: return "Telegram"
        case .groupme:  return "GroupMe"
        }
    }
}

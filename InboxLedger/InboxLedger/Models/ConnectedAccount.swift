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

// ServiceIcon.swift
// Ledger
//
// Brand icons for each service.
// Tries to load actual logo from asset catalog first (e.g. "logo_gmail").
// Falls back to a styled lettermark if image not found.
//
// TO ADD REAL LOGOS:
// 1. In Xcode → Assets.xcassets, create new Image Set for each:
//    - "logo_gmail"   (Google's Gmail icon)
//    - "logo_outlook" (Microsoft Outlook icon)
//    - "logo_teams"   (Microsoft Teams icon)
//    - "logo_slack"   (Slack icon)
//    - "logo_telegram" (Telegram icon)
// 2. Drag the PNG/SVG into the 2x or 3x slot
// 3. ServiceIcon will automatically use the real logo

import SwiftUI

struct ServiceIcon: View {
    let service: AccountService
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let img = UIImage(named: assetName) {
                // Real logo from asset catalog
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                // Styled lettermark fallback
                Text(lettermark)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: size, height: size)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
    }

    private var assetName: String {
        switch service {
        case .gmail:    return "logo_gmail"
        case .outlook:  return "logo_outlook"
        case .teams:    return "logo_teams"
        case .slack:    return "logo_slack"
        case .telegram: return "logo_telegram"
        case .groupme:  return "logo_groupme"
        }
    }

    private var lettermark: String {
        switch service {
        case .gmail:    return "G"
        case .outlook:  return "O"
        case .teams:    return "T"
        case .slack:    return "S"
        case .telegram: return "T"
        case .groupme:  return "GM"
        }
    }

    private var color: Color {
        switch service {
        case .gmail:    return Color(red: 0.86, green: 0.20, blue: 0.18)  // Gmail red
        case .outlook:  return Color(red: 0.00, green: 0.47, blue: 0.84)  // Outlook blue
        case .teams:    return Color(red: 0.29, green: 0.21, blue: 0.55)  // Teams purple
        case .slack:    return Color(red: 0.24, green: 0.10, blue: 0.36)  // Slack aubergine
        case .telegram: return Color(red: 0.16, green: 0.63, blue: 0.87)  // Telegram blue
        case .groupme:  return Color(red: 0.00, green: 0.64, blue: 0.87)  // GroupMe teal
        }
    }
}

/// Source icon for LedgerSource (includes iMessage)
struct SourceIcon: View {
    let source: LedgerSource
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let img = UIImage(named: assetName) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Text(lettermark)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: size, height: size)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
    }

    private var assetName: String {
        switch source {
        case .gmail:    return "logo_gmail"
        case .outlook:  return "logo_outlook"
        case .teams:    return "logo_teams"
        case .slack:    return "logo_slack"
        case .telegram: return "logo_telegram"
        case .imessage: return "logo_imessage"
        case .groupme:  return "logo_groupme"
        }
    }

    private var lettermark: String {
        switch source {
        case .gmail:    return "G"
        case .outlook:  return "O"
        case .teams:    return "T"
        case .slack:    return "S"
        case .telegram: return "T"
        case .imessage: return "iM"
        case .groupme:  return "GM"
        }
    }

    private var color: Color {
        switch source {
        case .gmail:    return Color(red: 0.86, green: 0.20, blue: 0.18)
        case .outlook:  return Color(red: 0.00, green: 0.47, blue: 0.84)
        case .teams:    return Color(red: 0.29, green: 0.21, blue: 0.55)
        case .slack:    return Color(red: 0.24, green: 0.10, blue: 0.36)
        case .telegram: return Color(red: 0.16, green: 0.63, blue: 0.87)
        case .imessage: return Color(red: 0.20, green: 0.55, blue: 0.30)
        case .groupme:  return Color(red: 0.00, green: 0.64, blue: 0.87)
        }
    }
}

// EmailAttachment.swift
// Ledger
//
// Represents a file attached to an email (PDF, image, video, etc.)
// and actionable links detected in the email body.

import Foundation
import SwiftUI

// MARK: - Email Attachment

struct EmailAttachment: Identifiable, Equatable, Codable {
    let id: String              // Gmail attachmentId or Outlook attachment id
    let filename: String
    let mimeType: String
    let size: Int               // bytes
    let isInline: Bool          // true = inline image (logo/signature), false = real attachment

    enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, size, isInline
    }

    /// Human-readable file size
    var formattedSize: String {
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        let mb = Double(size) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    /// General file type category
    var fileType: FileType {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return .image }
        if lower == "application/pdf" { return .pdf }
        if lower.hasPrefix("video/") { return .video }
        if lower.hasPrefix("audio/") { return .audio }
        if lower.contains("spreadsheet") || lower.contains("excel") || filename.hasSuffix(".xlsx") || filename.hasSuffix(".csv") { return .spreadsheet }
        if lower.contains("document") || lower.contains("word") || filename.hasSuffix(".docx") || filename.hasSuffix(".doc") { return .document }
        if lower.contains("presentation") || lower.contains("powerpoint") || filename.hasSuffix(".pptx") { return .presentation }
        if lower.contains("zip") || lower.contains("compressed") || lower.contains("tar") || lower.contains("rar") { return .archive }
        return .other
    }

    enum FileType {
        case image, pdf, video, audio, document, spreadsheet, presentation, archive, other

        var icon: String {
            switch self {
            case .image:        return "photo"
            case .pdf:          return "doc.richtext"
            case .video:        return "film"
            case .audio:        return "waveform"
            case .document:     return "doc.text"
            case .spreadsheet:  return "tablecells"
            case .presentation: return "rectangle.on.rectangle"
            case .archive:      return "doc.zipper"
            case .other:        return "paperclip"
            }
        }

        var color: Color {
            switch self {
            case .image:        return Color(red: 0.25, green: 0.55, blue: 0.70)
            case .pdf:          return Color(red: 0.75, green: 0.22, blue: 0.17)
            case .video:        return Color(red: 0.55, green: 0.30, blue: 0.65)
            case .audio:        return Color(red: 0.80, green: 0.50, blue: 0.15)
            case .document:     return Color(red: 0.20, green: 0.45, blue: 0.70)
            case .spreadsheet:  return Color(red: 0.20, green: 0.60, blue: 0.35)
            case .presentation: return Color(red: 0.85, green: 0.45, blue: 0.15)
            case .archive:      return Color(red: 0.45, green: 0.45, blue: 0.45)
            case .other:        return Color(red: 0.50, green: 0.50, blue: 0.50)
            }
        }

        var label: String {
            switch self {
            case .image:        return "Image"
            case .pdf:          return "PDF"
            case .video:        return "Video"
            case .audio:        return "Audio"
            case .document:     return "Document"
            case .spreadsheet:  return "Spreadsheet"
            case .presentation: return "Presentation"
            case .archive:      return "Archive"
            case .other:        return "File"
            }
        }
    }
}

// MARK: - Detected Link

struct DetectedLink: Identifiable, Equatable, Codable {
    let id: String
    let url: URL
    let displayText: String     // Cleaned-up display label
    let linkType: LinkType

    init(url: URL, displayText: String, linkType: LinkType) {
        self.id = UUID().uuidString
        self.url = url
        self.displayText = displayText
        self.linkType = linkType
    }

    enum LinkType: String, Codable {
        case scheduling     // Calendly, Doodle, When2Meet, cal.com
        case meeting        // Zoom, Google Meet, Teams meeting, Webex
        case document       // Google Docs, Sheets, Slides, Dropbox, OneDrive
        case payment        // Venmo, PayPal, CashApp, Zelle, Stripe
        case form           // Google Forms, Typeform, SurveyMonkey, DocuSign
        case social         // Instagram, Twitter, LinkedIn posts
        case code           // GitHub, GitLab, Bitbucket
        case generic        // Everything else

        var icon: String {
            switch self {
            case .scheduling:   return "calendar.badge.clock"
            case .meeting:      return "video"
            case .document:     return "doc.text"
            case .payment:      return "creditcard"
            case .form:         return "list.clipboard"
            case .social:       return "at"
            case .code:         return "chevron.left.forwardslash.chevron.right"
            case .generic:      return "link"
            }
        }

        var color: Color {
            switch self {
            case .scheduling:   return Color(red: 0.20, green: 0.60, blue: 0.35)
            case .meeting:      return Color(red: 0.25, green: 0.45, blue: 0.75)
            case .document:     return Color(red: 0.20, green: 0.45, blue: 0.70)
            case .payment:      return Color(red: 0.60, green: 0.40, blue: 0.75)
            case .form:         return Color(red: 0.80, green: 0.50, blue: 0.15)
            case .social:       return Color(red: 0.55, green: 0.30, blue: 0.65)
            case .code:         return Color(red: 0.35, green: 0.35, blue: 0.35)
            case .generic:      return Color(red: 0.50, green: 0.50, blue: 0.50)
            }
        }

        var label: String {
            switch self {
            case .scheduling:   return "Schedule"
            case .meeting:      return "Meeting"
            case .document:     return "Document"
            case .payment:      return "Payment"
            case .form:         return "Form"
            case .social:       return "Social"
            case .code:         return "Code"
            case .generic:      return "Link"
            }
        }
    }
}

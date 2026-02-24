// LinkDetector.swift
// Ledger
//
// Extracts actionable URLs from email bodies and classifies them by type.
// Filters out tracking pixels, unsubscribe links, and other non-actionable URLs.

import Foundation

final class LinkDetector {

    static let shared = LinkDetector()
    private init() {}

    // MARK: - Public

    /// Extracts and classifies all actionable links from an email body.
    func detectLinks(in body: String) -> [DetectedLink] {
        let urls = extractURLs(from: body)
        return urls
            .filter { !isJunkURL($0) }
            .compactMap { classify($0) }
            .deduplicated()
    }

    // MARK: - URL Extraction

    private func extractURLs(from text: String) -> [URL] {
        let types: NSTextCheckingResult.CheckingType = .link
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        return matches.compactMap { $0.url }.filter { isSafeURL($0) }
    }

    // MARK: - URL Safety Gate

    /// Only allow URLs that are safe to open in SFSafariViewController.
    /// Rejects anything that could crash, confuse, or harm the user.
    private func isSafeURL(_ url: URL) -> Bool {
        // MUST be http or https — reject mailto:, tel:, ftp:, data:, file:, javascript:, etc.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }

        // MUST have a valid host
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        // Reject IP addresses (often phishing or tracking)
        let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        if host.range(of: ipPattern, options: .regularExpression) != nil { return false }

        // Reject localhost and private networks
        let dangerousHosts = ["localhost", "127.0.0.1", "0.0.0.0", "::1",
                              "10.", "172.16.", "192.168."]
        if dangerousHosts.contains(where: { host.hasPrefix($0) || host == $0 }) { return false }

        // Reject single-segment domains (no TLD) — e.g. "http://intranet"
        if !host.contains(".") { return false }

        // Reject suspiciously encoded URLs (potential attack vectors)
        let full = url.absoluteString
        if full.contains("%00") || full.contains("%0a") || full.contains("%0d") { return false }
        if full.contains("javascript:") || full.contains("data:") { return false }

        // Reject extremely short hosts (likely malformed)
        if host.count < 4 { return false }

        return true
    }

    // MARK: - Junk URL Filter

    /// Filters out tracking pixels, unsubscribe links, email footers, and other noise.
    private func isJunkURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let full = url.absoluteString.lowercased()

        // Tracking / analytics
        let trackingDomains = [
            "click.", "track.", "trk.", "t.co", "bit.ly", "goo.gl",
            "mailchimp.com", "list-manage.com", "sendgrid.net",
            "mandrillapp.com", "postmarkapp.com", "mailgun.org",
            "email-analytics", "email.mg.", "cmail", "createsend",
            "constantcontact.com", "campaign-archive"
        ]
        if trackingDomains.contains(where: { host.contains($0) || full.contains($0) }) { return true }

        // Unsubscribe / preferences / opt-out
        let unsubPatterns = ["unsubscribe", "optout", "opt-out", "email-preferences",
                             "manage-preferences", "notification-settings", "email-settings",
                             "subscription-preferences"]
        if unsubPatterns.contains(where: { full.contains($0) }) { return true }

        // Tracking paths
        let trackingPaths = ["/track", "/click", "/open", "/beacon", "/pixel",
                             "/wf/click", "/e/", "/c/", "/o/", "/__"]
        if trackingPaths.contains(where: { path.hasPrefix($0) }) { return true }

        // 1x1 pixel image URLs
        if full.contains("1x1") || full.contains("spacer.gif") || full.contains("blank.gif") { return true }

        // Very long URLs with lots of params are usually tracking
        if url.absoluteString.count > 300 { return true }

        // Email footer noise
        let footerDomains = ["mailchimp.com", "constantcontact.com", "hubspot.com",
                             "salesforce.com", "pardot.com", "marketo.com"]
        if footerDomains.contains(where: { host.contains($0) }) { return true }

        return false
    }

    // MARK: - Link Classification

    private func classify(_ url: URL) -> DetectedLink? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let full = url.absoluteString.lowercased()

        let linkType = classifyType(host: host, path: path, full: full)
        let displayText = generateDisplayText(url: url, host: host, type: linkType)

        return DetectedLink(url: url, displayText: displayText, linkType: linkType)
    }

    private func classifyType(host: String, path: String, full: String) -> DetectedLink.LinkType {
        // Scheduling
        let schedulingDomains = ["calendly.com", "cal.com", "doodle.com", "when2meet.com",
                                 "meetingbird.com", "zcal.co", "savvycal.com", "tidycal.com",
                                 "youcanbook.me", "acuityscheduling.com", "koalendar.com"]
        if schedulingDomains.contains(where: { host.contains($0) }) { return .scheduling }
        if host.contains("outlook.office") && full.contains("bookings") { return .scheduling }

        // Video meetings
        let meetingDomains = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com",
                              "teams.live.com", "webex.com", "whereby.com", "around.co",
                              "gather.town", "discord.gg"]
        if meetingDomains.contains(where: { host.contains($0) }) { return .meeting }
        if host.contains("zoom") && path.contains("/j/") { return .meeting }

        // Documents
        let docDomains = ["docs.google.com", "sheets.google.com", "slides.google.com",
                          "drive.google.com", "dropbox.com", "dl.dropboxusercontent.com",
                          "onedrive.live.com", "sharepoint.com", "notion.so", "notion.site",
                          "coda.io", "airtable.com", "figma.com", "miro.com",
                          "canva.com", "box.com", "paper.dropbox.com"]
        if docDomains.contains(where: { host.contains($0) }) { return .document }
        if host.contains("1drv.ms") { return .document }

        // Payments
        let paymentDomains = ["venmo.com", "paypal.com", "paypal.me", "cash.app",
                              "square.com", "zelle.com", "stripe.com", "invoice.stripe.com",
                              "buy.stripe.com", "checkout.stripe.com", "splitwise.com",
                              "request.network"]
        if paymentDomains.contains(where: { host.contains($0) }) { return .payment }

        // Forms / signing
        let formDomains = ["forms.google.com", "docs.google.com/forms", "typeform.com",
                           "surveymonkey.com", "jotform.com", "tally.so", "airtable.com/shr",
                           "docusign.com", "docusign.net", "hellosign.com", "pandadoc.com",
                           "sign.com", "adobe.com/sign"]
        if formDomains.contains(where: { full.contains($0) }) { return .form }

        // Code
        let codeDomains = ["github.com", "gitlab.com", "bitbucket.org", "gist.github.com",
                           "codepen.io", "replit.com", "codesandbox.io", "stackblitz.com"]
        if codeDomains.contains(where: { host.contains($0) }) { return .code }

        // Social
        let socialDomains = ["instagram.com", "twitter.com", "x.com",
                             "linkedin.com/posts", "linkedin.com/feed",
                             "facebook.com", "tiktok.com", "threads.net"]
        if socialDomains.contains(where: { full.contains($0) }) { return .social }

        return .generic
    }

    private func generateDisplayText(url: URL, host: String, type: DetectedLink.LinkType) -> String {
        // Use known brand names for common services
        let brandNames: [String: String] = [
            "calendly.com": "Calendly", "cal.com": "Cal.com", "doodle.com": "Doodle",
            "when2meet.com": "When2Meet",
            "zoom.us": "Zoom", "zoom.com": "Zoom",
            "meet.google.com": "Google Meet",
            "teams.microsoft.com": "Teams Meeting", "teams.live.com": "Teams Meeting",
            "webex.com": "Webex",
            "docs.google.com": "Google Doc", "sheets.google.com": "Google Sheet",
            "slides.google.com": "Google Slides", "drive.google.com": "Google Drive",
            "dropbox.com": "Dropbox", "notion.so": "Notion", "notion.site": "Notion",
            "figma.com": "Figma", "miro.com": "Miro", "canva.com": "Canva",
            "sharepoint.com": "SharePoint", "onedrive.live.com": "OneDrive",
            "venmo.com": "Venmo", "paypal.com": "PayPal", "paypal.me": "PayPal",
            "cash.app": "Cash App", "splitwise.com": "Splitwise",
            "docusign.com": "DocuSign", "docusign.net": "DocuSign",
            "hellosign.com": "HelloSign",
            "forms.google.com": "Google Form", "typeform.com": "Typeform",
            "surveymonkey.com": "Survey",
            "github.com": "GitHub", "gitlab.com": "GitLab",
        ]

        for (domain, brand) in brandNames {
            if host.contains(domain) { return brand }
        }

        // Fallback: clean the hostname
        var display = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "m.", with: "")

        // Capitalize first letter
        if let first = display.first {
            display = first.uppercased() + display.dropFirst()
        }

        // Truncate very long domains
        if display.count > 25 {
            display = String(display.prefix(22)) + "…"
        }

        return display
    }
}

// MARK: - Deduplication

private extension Array where Element == DetectedLink {
    /// Removes links pointing to the same host+path (ignores query params)
    func deduplicated() -> [DetectedLink] {
        var seen = Set<String>()
        return filter { link in
            let key = (link.url.host ?? "") + link.url.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }
}

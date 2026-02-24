// SafariView.swift
// Ledger
//
// In-app browser for opening links without leaving Ledger.
// Uses SFSafariViewController for native, fast, secure browsing.

import SwiftUI
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    /// Whether this URL is safe to open in SFSafariViewController
    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil && !url.host!.isEmpty
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        // Final safety check — if somehow a bad URL got through, use a fallback
        let safeURL: URL
        if SafariView.canOpen(url) {
            safeURL = url
        } else {
            // This should never happen, but if it does, show a blank safe page
            safeURL = URL(string: "https://example.com")!
        }

        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true

        let safari = SFSafariViewController(url: safeURL, configuration: config)
        safari.preferredControlTintColor = UIColor(red: 0.15, green: 0.14, blue: 0.13, alpha: 1.0)
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

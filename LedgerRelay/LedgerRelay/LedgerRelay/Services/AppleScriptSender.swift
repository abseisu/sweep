// AppleScriptSender.swift
// Sends iMessages via osascript subprocess through the Messages app.
// Uses Process instead of NSAppleScript for more reliable Automation (TCC) permission handling.

import Foundation

enum AppleScriptSender {

    /// Send an iMessage to a phone number or email address.
    /// Returns true if the message was sent successfully.
    @discardableResult
    static func sendMessage(to recipient: String, text: String) async -> Bool {
        // Validate recipient format — must look like a phone number or email
        let recipientPattern = #"^[\w.+\-@]+$|^\+?[\d\s\-().]+$"#
        guard recipient.range(of: recipientPattern, options: .regularExpression) != nil else {
            print("❌ Invalid recipient format: \(recipient.prefix(20))")
            return false
        }

        // Escape for shell embedding inside osascript
        var escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Remove control characters that could break AppleScript strings
        escapedText = escapedText.replacingOccurrences(of: "\n", with: " ")
        escapedText = escapedText.replacingOccurrences(of: "\r", with: " ")
        escapedText = escapedText.replacingOccurrences(of: "\t", with: " ")
        // Remove any remaining non-printable characters
        escapedText = String(escapedText.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })

        var escapedRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Remove control characters that could break AppleScript strings
        escapedRecipient = escapedRecipient.replacingOccurrences(of: "\n", with: " ")
        escapedRecipient = escapedRecipient.replacingOccurrences(of: "\r", with: " ")
        escapedRecipient = escapedRecipient.replacingOccurrences(of: "\t", with: " ")
        // Remove any remaining non-printable characters
        escapedRecipient = String(escapedRecipient.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })

        // Primary approach: send via iMessage service buddy
        let script = """
        tell application "Messages"
            set targetBuddy to "\(escapedRecipient)"
            set targetService to 1st account whose service type = iMessage
            set theBuddy to participant targetBuddy of targetService
            send "\(escapedText)" to theBuddy
        end tell
        """

        if await runOsascript(script) {
            return true
        }

        print("⚠️ Primary send failed, trying alternate approach...")

        // Fallback: send via buddy reference
        let altScript = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to buddy "\(escapedRecipient)" of targetService
            send "\(escapedText)" to targetBuddy
        end tell
        """

        if await runOsascript(altScript) {
            return true
        }

        print("⚠️ Alternate send also failed, trying direct chat approach...")

        // Last resort: try sending to a chat with this recipient
        let chatScript = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            send "\(escapedText)" to buddy "\(escapedRecipient)" of targetService
        end tell
        """

        return await runOsascript(chatScript)
    }

    /// Check if we have Automation permission for Messages.
    /// Returns true if permission is granted.
    static func checkAutomationPermission() -> Bool {
        let script = """
        tell application "Messages"
            count of conversations
        end tell
        """
        return runOsascriptSync(script)
    }

    // MARK: - Private

    /// Synchronous version for permission checks that don't need to be off-loaded.
    private static func runOsascriptSync(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Run an AppleScript via osascript subprocess off the main thread.
    /// Using Process/osascript is more reliable than NSAppleScript for TCC permission handling.
    private static func runOsascript(_ script: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let exitCode = process.terminationStatus
                    if exitCode == 0 {
                        continuation.resume(returning: true)
                        return
                    }

                    // Read stderr for diagnostics
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    print("❌ osascript failed (exit \(exitCode)): \(stderrStr.prefix(200))")

                    // Check for specific TCC/permission errors
                    if stderrStr.contains("not permitted") || stderrStr.contains("1743") || stderrStr.contains("not allowed") {
                        print("🔒 This is an Automation permission error — Messages access not granted")
                    }

                    continuation.resume(returning: false)
                } catch {
                    print("❌ Failed to launch osascript: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

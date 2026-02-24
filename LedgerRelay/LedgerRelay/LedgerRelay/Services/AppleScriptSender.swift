// AppleScriptSender.swift
// Sends iMessages via osascript subprocess through the Messages app.
// Uses Process instead of NSAppleScript for more reliable Automation (TCC) permission handling.

import Foundation

enum AppleScriptSender {

    /// Send an iMessage to a phone number or email address.
    /// Returns true if the message was sent successfully.
    @discardableResult
    static func sendMessage(to recipient: String, text: String) -> Bool {
        // Sanitize for safe embedding in AppleScript quoted strings.
        // CRITICAL: Must escape ALL characters that could break out of
        // the string context — not just quotes and backslashes.
        let escapedText = sanitizeForAppleScript(text)
        let escapedRecipient = sanitizeForAppleScript(recipient)

        // Primary approach: send via iMessage service buddy
        let script = """
        tell application "Messages"
            set targetBuddy to "\(escapedRecipient)"
            set targetService to 1st account whose service type = iMessage
            set theBuddy to participant targetBuddy of targetService
            send "\(escapedText)" to theBuddy
        end tell
        """

        if runOsascript(script) {
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

        if runOsascript(altScript) {
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

        return runOsascript(chatScript)
    }

    /// Check if we have Automation permission for Messages.
    /// Returns true if permission is granted.
    static func checkAutomationPermission() -> Bool {
        let script = """
        tell application "Messages"
            count of conversations
        end tell
        """
        return runOsascript(script)
    }

    // MARK: - Private

    /// Sanitize a string for safe interpolation into an AppleScript quoted string.
    /// Strips all control characters (newlines, tabs, carriage returns, etc.) that could
    /// break out of the quoted string context and inject arbitrary AppleScript commands.
    /// Then escapes backslashes and double quotes.
    private static func sanitizeForAppleScript(_ input: String) -> String {
        var result = ""
        for scalar in input.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            default:
                // Strip control characters (U+0000–U+001F and U+007F).
                // These include \n, \r, \t which could break AppleScript string boundaries.
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += " "
                } else {
                    result += String(scalar)
                }
            }
        }
        return result
    }

    /// Run an AppleScript via osascript subprocess.
    /// Using Process/osascript is more reliable than NSAppleScript for TCC permission handling.
    private static func runOsascript(_ script: String) -> Bool {
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
                return true
            }

            // Read stderr for diagnostics
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            print("❌ osascript failed (exit \(exitCode)): \(stderrStr.prefix(200))")

            // Check for specific TCC/permission errors
            if stderrStr.contains("not permitted") || stderrStr.contains("1743") || stderrStr.contains("not allowed") {
                print("🔒 This is an Automation permission error — Messages access not granted")
            }

            return false
        } catch {
            print("❌ Failed to launch osascript: \(error.localizedDescription)")
            return false
        }
    }
}

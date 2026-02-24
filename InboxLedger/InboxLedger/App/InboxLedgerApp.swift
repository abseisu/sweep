// InboxLedgerApp.swift
// Inbox Ledger
//
// App entry point — configures Google Sign-In, MSAL, notifications, APNs, and the root scene.
//
// BACKEND INTEGRATION:
// - Registers for remote (push) notifications via APNs
// - Forwards device token to backend for push notification delivery
// - Handles push notification deep links (batch, window, urgent)

import SwiftUI
import GoogleSignIn
import MSAL

@main
struct InboxLedgerApp: App {
    @StateObject private var appState = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    // MSAL handles its own redirect
                    MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
                    // Google handles its own redirect
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

// MARK: - AppDelegate for notification registration + MSAL URL handling + APNs

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.requestPermission()
        NotificationManager.shared.registerCategories()
        NotificationManager.shared.registerStackCategories()

        // Register for remote push notifications (APNs)
        UIApplication.shared.registerForRemoteNotifications()

        // Register background fetch for stack mode
        UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

        return true
    }

    // MARK: - APNs Device Token

    /// Called when APNs successfully registers and provides a device token.
    /// Forwards the token to the Ledger backend for push notification delivery.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("📲 APNs device token: \(token.prefix(16))...")
        Task {
            await BackendManager.shared.updateDeviceToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("⚠️ APNs registration failed: \(error.localizedDescription)")
    }

    // Background fetch handler — used in stack mode to check for new emails
    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let mode = UserDefaults.standard.string(forKey: "ledger_mode") ?? "stack"
        guard mode == "stack" else {
            completionHandler(.noData)
            return
        }
        completionHandler(.newData)
    }

    // MSAL redirect handling
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        let sourceApp = options[.sourceApplication] as? String
        if MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: sourceApp) {
            return true
        }
        return GIDSignIn.sharedInstance.handle(url)
    }

    // Suppress notifications while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    // Handle notification actions (Open Now / Postpone 1h / Backend push taps)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case "POSTPONE_1H":
            NotificationCenter.default.post(name: .ledgerPostpone, object: nil)

        case "OPEN_LEDGER", "OPEN_URGENT", UNNotificationDefaultActionIdentifier:
            // Handle backend push notification types
            if let type = userInfo["type"] as? String {
                switch type {
                case "batch", "window", "urgent":
                    // Open dashboard — the app will handle showing the right view
                    NotificationCenter.default.post(name: .ledgerOpenDashboard, object: nil)
                default:
                    break
                }
            }

        default:
            break
        }

        completionHandler()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let ledgerPostpone = Notification.Name("ledgerPostpone")
    static let ledgerOpenDashboard = Notification.Name("ledgerOpenDashboard")
}

import ActivityKit
import SwiftUI
import TimSharedKit
import UserNotifications

extension Notification.Name {
    /// Posted when an APNs push (alert tap OR silent background) asks the
    /// UI to refresh a specific tmux window's pane capture. userInfo
    /// carries "window": Int.
    static let paneRefreshRequested = Notification.Name("paneRefreshRequested")
    /// Posted when the user taps a notification. The UI should switch to
    /// the named tab. userInfo carries "window": Int.
    static let deepLinkToWindow = Notification.Name("deepLinkToWindow")
}

@main
struct TerminalApp: App {
    @StateObject private var server = ServerConnection()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TerminalView()
            }
            .environmentObject(server)
            .preferredColorScheme(.dark)
            .onAppear {
                appDelegate.server = server
                LiveActivityManager.shared.server = server
                LiveActivityManager.shared.startObservers()
            }
        }
    }
}

/// AppDelegate to handle push notification registration.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var server: ServerConnection?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Register actionable-notification category so alert-responder
        // proposals show Accept / Reject / Discuss buttons directly on the
        // lock-screen banner, not just inside the app.
        let acceptAction = UNNotificationAction(
            identifier: "PROPOSAL_ACCEPT",
            title: "Accept",
            options: [.authenticationRequired]
        )
        let rejectAction = UNNotificationAction(
            identifier: "PROPOSAL_REJECT",
            title: "Reject",
            options: [.destructive]
        )
        let discussAction = UNNotificationAction(
            identifier: "PROPOSAL_DISCUSS",
            title: "Discuss",
            options: [.foreground]
        )
        let proposalCategory = UNNotificationCategory(
            identifier: "PROPOSAL_ACTIONS",
            actions: [acceptAction, rejectAction, discussAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([proposalCategory])

        // Request permission and register for remote notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }

        // Cold-launch via notification tap: seed the deep-link so the root
        // view routes to the right tab once the scene is ready.
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let window = AppDelegate.windowIndex(from: remote) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .deepLinkToWindow,
                                                object: nil,
                                                userInfo: ["window": window])
            }
        }
        return true
    }

    /// Silent content-available push → wake up and ask the pane view to
    /// pre-fetch the fresh capture before the user foregrounds the app.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if let window = AppDelegate.windowIndex(from: userInfo) {
            NotificationCenter.default.post(name: .paneRefreshRequested,
                                            object: nil,
                                            userInfo: ["window": window])
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }

    static func windowIndex(from userInfo: [AnyHashable: Any]) -> Int? {
        if let w = userInfo["window"] as? Int { return w }
        if let s = userInfo["window"] as? String, let w = Int(s) { return w }
        return nil
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("APNs device token: \(token)")

        // Store token for re-registration on reconnect
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")

        // Send token to server
        guard let server = server,
              let url = URL(string: "\(server.baseURL)/register-device") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_token": token])
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                print("Failed to register device token: \(error)")
            } else {
                print("Device token registered with server")
            }
        }.resume()
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for push: \(error)")
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Even for foreground alerts, kick a pane refresh for the target
        // tab so the user sees Claude's reply without switching away.
        let info = notification.request.content.userInfo
        if let window = AppDelegate.windowIndex(from: info) {
            NotificationCenter.default.post(name: .paneRefreshRequested,
                                            object: nil,
                                            userInfo: ["window": window])
        }
        completionHandler([.banner, .sound])
    }

    // Tap on a delivered notification → deep-link to its tab.
    // Actionable-button taps on a proposal notification → POST the action
    // to the alert-responder endpoint so it fires even when the app is
    // still in the background (user never opens the tab).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier

        // Map the iOS-side action identifier to the server-side action verb.
        let proposalAction: String? = {
            switch actionId {
            case "PROPOSAL_ACCEPT":  return "accept"
            case "PROPOSAL_REJECT":  return "reject"
            case "PROPOSAL_DISCUSS": return "discuss"
            default: return nil
            }
        }()

        if let action = proposalAction,
           let alertId = info["alert_id"] as? String,
           let server = self.server,
           let url = URL(string: "\(server.baseURL)/internal/proposal-action/\(alertId)/\(action)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !server.authToken.isEmpty {
                req.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try? JSONSerialization.data(
                withJSONObject: ["source": "push-action"]
            )
            URLSession.shared.dataTask(with: req) { _, _, error in
                if let error = error {
                    print("Proposal action POST failed: \(error)")
                }
                DispatchQueue.main.async { completionHandler() }
            }.resume()
            // For Discuss, we ALSO deep-link to the freshly-opened window
            // so the user lands directly in the discussion tab.
            if action == "discuss", let window = AppDelegate.windowIndex(from: info) {
                NotificationCenter.default.post(name: .deepLinkToWindow,
                                                object: nil,
                                                userInfo: ["window": window])
            }
            return
        }

        // Default tap (not an actionable button) — deep-link to the tab.
        if let window = AppDelegate.windowIndex(from: info) {
            NotificationCenter.default.post(name: .deepLinkToWindow,
                                            object: nil,
                                            userInfo: ["window": window])
            NotificationCenter.default.post(name: .paneRefreshRequested,
                                            object: nil,
                                            userInfo: ["window": window])
        }
        completionHandler()
    }
}

/// Manages ActivityKit Live Activities: registers push-to-start tokens,
/// forwards per-activity update tokens to the conversation server, and
/// exposes a helper to request a local Activity when the user kicks off
/// a turn from the phone.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    weak var server: ServerConnection?
    private var started = false

    private init() {}

    /// Post a single diagnostic line to the server so iOS-side Live Activity
    /// events are visible in `/tmp/claude_sessions/server.log` alongside the
    /// APNs push-side logs. Fire-and-forget, survives offline.
    func postDiag(_ msg: String) {
        Task.detached { [weak self] in
            guard let server = await self?.server,
                  let url = URL(string: "\(server.baseURL)/la-diag") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !server.authToken.isEmpty {
                req.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
            }
            let payload: [String: Any] = ["msg": msg, "session": "mobile"]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func startObservers() {
        guard !started else { return }
        started = true
        postDiag("startObservers fired; activitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled) existingCount=\(Activity<ClaudeActivityAttributes>.activities.count)")

        // Watch for push-to-start token updates and register each one.
        Task { [weak self] in
            if #available(iOS 17.2, *) {
                for await tokenData in Activity<ClaudeActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    print("Live Activity push-to-start token: \(hex)")
                    self?.postDiag("pushToStart token received prefix=\(String(hex.prefix(16)))")
                    await self?.register(startToken: hex)
                }
            } else {
                print("Live Activity push-to-start requires iOS 17.2+")
            }
        }

        // Watch existing and future activities so we can register their update tokens.
        Task { [weak self] in
            for await activity in Activity<ClaudeActivityAttributes>.activityUpdates {
                self?.postDiag("activityUpdates yielded id=\(activity.id) state=\(activity.activityState) sessionLabel=\(activity.attributes.sessionLabel)")
                await self?.observe(activity: activity)
            }
        }
    }

    /// Start a local Live Activity when the user sends a message from the phone.
    /// Returns the started activity, or nil if activities are not enabled or one
    /// is already running for the same session label.
    @discardableResult
    func startLocalActivity(sessionLabel: String = "mobile",
                            headline: String = "Working…") -> Activity<ClaudeActivityAttributes>? {
        postDiag("startLocalActivity called sessionLabel=\(sessionLabel) headline=\(headline)")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities not enabled")
            postDiag("startLocalActivity aborted: Activities not enabled in Settings")
            return nil
        }
        if Activity<ClaudeActivityAttributes>.activities.contains(where: { $0.attributes.sessionLabel == sessionLabel && $0.activityState == .active }) {
            postDiag("startLocalActivity aborted: active activity already exists for sessionLabel=\(sessionLabel)")
            return nil
        }
        let state = ClaudeActivityAttributes.ContentState(
            phase: .thinking,
            headline: headline,
            body: "",
            startedAt: Date()
        )
        let attributes = ClaudeActivityAttributes(sessionLabel: sessionLabel)
        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            postDiag("Activity.request succeeded id=\(activity.id)")
            Task { await observe(activity: activity) }
            return activity
        } catch {
            print("Failed to start Live Activity: \(error)")
            postDiag("Activity.request threw: \(error.localizedDescription)")
            return nil
        }
    }

    private func observe(activity: Activity<ClaudeActivityAttributes>) async {
        postDiag("observe() started for id=\(activity.id); waiting pushTokenUpdates")
        // Register the activity's current push token immediately (if one
        // exists). pushTokenUpdates only yields NEW tokens, so an
        // activity that was created via push-to-start before this observer
        // attached may have a valid token cached on the activity but no
        // update event to replay. Reading activity.pushToken synchronously
        // covers that case.
        if let existing = activity.pushToken {
            let hex = existing.map { String(format: "%02x", $0) }.joined()
            postDiag("observe() existing pushToken id=\(activity.id) tokenPrefix=\(String(hex.prefix(16)))")
            await register(activity: activity, token: hex)
        }
        for await tokenData in activity.pushTokenUpdates {
            let hex = tokenData.map { String(format: "%02x", $0) }.joined()
            print("Live Activity update token for \(activity.id): \(hex)")
            postDiag("pushTokenUpdates yielded id=\(activity.id) tokenPrefix=\(String(hex.prefix(16)))")
            await register(activity: activity, token: hex)
        }
        postDiag("observe() loop ended for id=\(activity.id) (activity probably dismissed)")
    }

    private func register(startToken hex: String) async {
        guard let server = server else {
            postDiag("register(startToken:) skipped — server is nil")
            return
        }
        guard let url = URL(string: "\(server.baseURL)/register-liveactivity-start-token") else {
            postDiag("register(startToken:) bad URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            req.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "bundle_id": "com.timtrailor.terminal",
            "token": hex,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            postDiag("POST /register-liveactivity-start-token → \(code) tokenPrefix=\(String(hex.prefix(16)))")
        } catch {
            postDiag("POST /register-liveactivity-start-token threw: \(error.localizedDescription)")
        }
    }

    private func register(activity: Activity<ClaudeActivityAttributes>, token: String?) async {
        guard let server = server else {
            postDiag("register(activity:) skipped — server is nil id=\(activity.id)")
            return
        }
        guard let url = URL(string: "\(server.baseURL)/register-liveactivity-token") else {
            postDiag("register(activity:) bad URL id=\(activity.id)")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            req.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        var payload: [String: Any] = [
            "activity_id": activity.id,
            "attributes": [
                "sessionLabel": activity.attributes.sessionLabel,
            ],
        ]
        if let token = token { payload["token"] = token }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let tokenPreview = token.map { String($0.prefix(16)) } ?? "nil"
            postDiag("POST /register-liveactivity-token → \(code) id=\(activity.id) tokenPrefix=\(tokenPreview)")
        } catch {
            postDiag("POST /register-liveactivity-token threw id=\(activity.id): \(error.localizedDescription)")
        }
    }
}

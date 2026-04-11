import ActivityKit
import SwiftUI
import TimSharedKit
import UserNotifications

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

        // Request permission and register for remote notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        return true
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
        completionHandler([.banner, .sound])
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

    func startObservers() {
        guard !started else { return }
        started = true

        // Watch for push-to-start token updates and register each one.
        Task { [weak self] in
            if #available(iOS 17.2, *) {
                for await tokenData in Activity<ClaudeActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    print("Live Activity push-to-start token: \(hex)")
                    await self?.register(startToken: hex)
                }
            } else {
                print("Live Activity push-to-start requires iOS 17.2+")
            }
        }

        // Watch existing and future activities so we can register their update tokens.
        Task { [weak self] in
            for await activity in Activity<ClaudeActivityAttributes>.activityUpdates {
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities not enabled")
            return nil
        }
        if Activity<ClaudeActivityAttributes>.activities.contains(where: { $0.attributes.sessionLabel == sessionLabel && $0.activityState == .active }) {
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
            Task { await observe(activity: activity) }
            return activity
        } catch {
            print("Failed to start Live Activity: \(error)")
            return nil
        }
    }

    private func observe(activity: Activity<ClaudeActivityAttributes>) async {
        // Wait for the first push token before registering — server stores
        // the token + activity_id + attributes in a single round-trip. Any
        // subsequent token rotations are forwarded on the same endpoint.
        for await tokenData in activity.pushTokenUpdates {
            let hex = tokenData.map { String(format: "%02x", $0) }.joined()
            print("Live Activity update token for \(activity.id): \(hex)")
            await register(activity: activity, token: hex)
        }
    }

    private func register(startToken hex: String) async {
        guard let server = server,
              let url = URL(string: "\(server.baseURL)/register-liveactivity-start-token") else { return }
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
            _ = try await URLSession.shared.data(for: req)
        } catch {
            print("start-token registration failed: \(error)")
        }
    }

    private func register(activity: Activity<ClaudeActivityAttributes>, token: String?) async {
        guard let server = server,
              let url = URL(string: "\(server.baseURL)/register-liveactivity-token") else { return }
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
            _ = try await URLSession.shared.data(for: req)
        } catch {
            print("activity-token registration failed: \(error)")
        }
    }
}

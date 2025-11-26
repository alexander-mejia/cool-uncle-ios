import Foundation
import UIKit

/// Phase 1: TestFlight Analytics + Bug Reports
/// Sends usage metrics and bug reports to Cloudflare backend
/// See: proposals/cloudflare.md
@MainActor
class CloudflareService: ObservableObject {
    static let shared = CloudflareService()

    private let baseURL = "https://cooluncle-backend.cooluncle.workers.dev"
    private let session: URLSession

    // Cache analytics events and batch send every 60 seconds
    private var analyticsQueue: [AnalyticsEvent] = []
    private var batchTimer: Timer?
    private let batchInterval: TimeInterval = 60.0

    // Session tracking
    private var sessionStartTime: Date?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        self.session = URLSession(configuration: config)

        // Start batch timer
        startBatchTimer()

        // Track session start
        startSession()
    }

    // MARK: - Analytics

    struct AnalyticsEvent: Codable {
        let user_id: String
        let timestamp: Int
        let call_type: String
        let action_type: String?
        let model_used: String
        let input_tokens: Int
        let output_tokens: Int
        let latency_ms: Int?
        let success: Bool
        let error_type: String?
        let cached_tokens: Int?
        let reasoning_tokens: Int?
        // Device metadata (Phase 1.6)
        let app_version: String?
        let build_number: String?
        let ios_version: String?
        let device_model: String?
    }

    /// Log AI call analytics (queued for batch sending)
    func logAnalytics(
        callType: String,
        actionType: String?,
        modelUsed: String,
        inputTokens: Int,
        outputTokens: Int,
        latencyMs: Int?,
        success: Bool,
        errorType: String? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        // Collect device metadata
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = DeviceInfo.getDeviceModel()

        let event = AnalyticsEvent(
            user_id: getUserID(),
            timestamp: Int(Date().timeIntervalSince1970),
            call_type: callType,
            action_type: actionType,
            model_used: modelUsed,
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            latency_ms: latencyMs,
            success: success,
            error_type: errorType,
            cached_tokens: cachedTokens,
            reasoning_tokens: reasoningTokens,
            app_version: appVersion,
            build_number: buildNumber,
            ios_version: iosVersion,
            device_model: deviceModel
        )

        analyticsQueue.append(event)
        AppLogger.verbose("📊 Analytics queued: \(callType) (\(analyticsQueue.count) pending)")
    }

    /// Send batched analytics to backend
    private func sendBatchedAnalytics() async {
        guard !analyticsQueue.isEmpty else { return }

        let batch = analyticsQueue
        analyticsQueue.removeAll()

        AppLogger.verbose("📤 Sending \(batch.count) analytics events to Cloudflare")

        var successCount = 0
        var failCount = 0

        for event in batch {
            do {
                try await sendAnalytics(event)
                successCount += 1
            } catch {
                failCount += 1
                AppLogger.verbose("⚠️ Analytics send failed: \(error.localizedDescription)")
                // Don't retry - analytics are fire-and-forget
            }
        }

        if successCount > 0 {
            AppLogger.verbose("✅ Telemetry uploaded: \(successCount) events sent to Cloudflare")
        }
        if failCount > 0 {
            AppLogger.verbose("❌ Telemetry errors: \(failCount) events failed to upload")
        }
    }

    private func sendAnalytics(_ event: AnalyticsEvent) async throws {
        guard let url = URL(string: "\(baseURL)/analytics") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(event)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw CloudflareError.httpError
        }
    }

    // MARK: - Bug Reports

    /// Phase 1: Enhanced bug report metadata structure
    struct BugReportMetadata {
        // User input (2 fields from form)
        let asrOriginal: String
        let userCorrected: String?
        let expectedBehavior: String

        // Device & app metadata
        let appVersion: String
        let buildNumber: String
        let iosVersion: String
        let deviceModel: String

        // Connection state
        let misterConnectionState: String
        let misterIPAddress: String
        let availableSystems: [String]

        // Game context
        let currentGameName: String?
        let currentGameSystem: String?
        let lastLaunchedGame: String?

        // AI context
        let lastActionType: String?
        let aiResponsePresent: Bool
        let commandGenerated: Bool

        // Speech state
        let speechAuthorized: Bool
        let siriEnablementRequired: Bool

        // Full session log
        let fullSessionLog: String
    }

    private struct BugReportPayload: Codable {
        let user_id: String
        let timestamp: Int
        let asr_original: String
        let user_corrected: String?
        let expected_behavior: String
        let app_version: String
        let build_number: String
        let ios_version: String
        let device_model: String
        let mister_connection_state: String
        let mister_ip_address: String
        let available_systems: String  // JSON array as string
        let current_game_name: String?
        let current_game_system: String?
        let last_launched_game: String?
        let last_action_type: String?
        let ai_response_present: Bool
        let command_generated: Bool
        let speech_authorized: Bool
        let siri_enablement_required: Bool
        let full_session_log: String
    }

    /// Submit bug report with enhanced metadata (Phase 1)
    /// Returns report ID from backend
    func submitBugReport(_ metadata: BugReportMetadata) async throws -> String {
        AppLogger.standard("🐛 Submitting bug report to \(baseURL)/bug-report")

        // Convert available systems array to JSON string
        let systemsJSON: String
        if let systemsData = try? JSONEncoder().encode(metadata.availableSystems),
           let systemsString = String(data: systemsData, encoding: .utf8) {
            systemsJSON = systemsString
        } else {
            systemsJSON = "[]"
        }

        let payload = BugReportPayload(
            user_id: getUserID(),
            timestamp: Int(Date().timeIntervalSince1970),
            asr_original: metadata.asrOriginal,
            user_corrected: metadata.userCorrected,
            expected_behavior: metadata.expectedBehavior,
            app_version: metadata.appVersion,
            build_number: metadata.buildNumber,
            ios_version: metadata.iosVersion,
            device_model: metadata.deviceModel,
            mister_connection_state: metadata.misterConnectionState,
            mister_ip_address: metadata.misterIPAddress,
            available_systems: systemsJSON,
            current_game_name: metadata.currentGameName,
            current_game_system: metadata.currentGameSystem,
            last_launched_game: metadata.lastLaunchedGame,
            last_action_type: metadata.lastActionType,
            ai_response_present: metadata.aiResponsePresent,
            command_generated: metadata.commandGenerated,
            speech_authorized: metadata.speechAuthorized,
            siri_enablement_required: metadata.siriEnablementRequired,
            full_session_log: metadata.fullSessionLog
        )

        guard let url = URL(string: "\(baseURL)/bug-report") else {
            AppLogger.standard("❌ Invalid URL: \(baseURL)/bug-report")
            throw CloudflareError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        AppLogger.standard("🐛 Sending bug report request...")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            AppLogger.standard("❌ Invalid HTTP response")
            throw CloudflareError.httpError
        }

        AppLogger.standard("🐛 Bug report response: HTTP \(httpResponse.statusCode)")

        // Handle rate limiting (429)
        if httpResponse.statusCode == 429 {
            // Try to extract retry_after_seconds from response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let retryAfter = json["retry_after_seconds"] as? Int {
                AppLogger.standard("⚠️ Bug report rate limited: \(retryAfter)s")
                throw CloudflareError.rateLimitExceeded(retryAfterSeconds: retryAfter)
            }
            throw CloudflareError.rateLimitExceeded(retryAfterSeconds: 3600)
        }

        // Log error responses
        if !(200...299).contains(httpResponse.statusCode) {
            if let responseString = String(data: data, encoding: .utf8) {
                AppLogger.standard("❌ Bug report failed: HTTP \(httpResponse.statusCode) - \(responseString)")
            } else {
                AppLogger.standard("❌ Bug report failed: HTTP \(httpResponse.statusCode)")
            }
            throw CloudflareError.httpError
        }

        // Extract report ID from response
        struct BugReportResponse: Codable {
            let success: Bool
            let report_id: String
        }

        if let response = try? JSONDecoder().decode(BugReportResponse.self, from: data) {
            AppLogger.standard("🐛 Bug report submitted successfully: \(response.report_id)")
            return response.report_id
        }

        // Log the response if we can't decode it
        if let responseString = String(data: data, encoding: .utf8) {
            AppLogger.standard("❌ Bug report: Could not extract report_id from response: \(responseString)")
        }

        throw CloudflareError.httpError
    }

    // MARK: - Helpers

    internal func getUserID() -> String {
        // Use device-specific anonymous ID (persists across app launches)
        let key = "cloudflare_user_id"
        if let existingID = UserDefaults.standard.string(forKey: key) {
            return existingID
        }

        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    private func startBatchTimer() {
        batchTimer = Timer.scheduledTimer(withTimeInterval: batchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sendBatchedAnalytics()
            }
        }
    }

    // MARK: - Session Tracking

    private func startSession() {
        sessionStartTime = Date()
        AppLogger.verbose("🕐 Session started")
    }

    /// Call this when the app is shutting down gracefully
    func endSession() async {
        // Send any pending analytics immediately
        await sendBatchedAnalytics()

        // Log session duration
        if let startTime = sessionStartTime {
            let sessionDuration = Int(Date().timeIntervalSince(startTime))
            logSessionEvent(durationSeconds: sessionDuration)
            await sendBatchedAnalytics() // Send session event immediately

            AppLogger.verbose("🕐 Session ended: \(sessionDuration)s")
        }

        sessionStartTime = nil
    }

    /// Restart session tracking (called when app returns from background)
    func restartSession() {
        startSession()
    }

    /// Log session event (special analytics event for session tracking)
    private func logSessionEvent(durationSeconds: Int) {
        // Collect device metadata
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = DeviceInfo.getDeviceModel()

        let event = AnalyticsEvent(
            user_id: getUserID(),
            timestamp: Int(Date().timeIntervalSince1970),
            call_type: "session",
            action_type: "session_end",
            model_used: "n/a",
            input_tokens: 0,
            output_tokens: 0,
            latency_ms: durationSeconds * 1000, // Store duration in latency_ms field
            success: true,
            error_type: nil,
            cached_tokens: nil,
            reasoning_tokens: nil,
            app_version: appVersion,
            build_number: buildNumber,
            ios_version: iosVersion,
            device_model: deviceModel
        )

        analyticsQueue.append(event)
    }

    deinit {
        batchTimer?.invalidate()
    }
}

// MARK: - Errors

enum CloudflareError: Error {
    case invalidURL
    case httpError
    case encodingError
    case rateLimitExceeded(retryAfterSeconds: Int)
}

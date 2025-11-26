import SwiftUI
import Foundation

struct MainAppView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var zaparooService: ZaparooService
    @Environment(\.scenePhase) private var scenePhase

    // Track if we've ever connected successfully - stay on ContentView during reconnection
    @State private var hasConnectedBefore = false

    // Timer to disconnect after extended inactivity (battery optimization)
    @State private var inactivityDisconnectTimer: Timer?
    private let inactivityDisconnectDelay: TimeInterval = 120 // 2 minutes

    init() {
        let settings = AppSettings()
        let zaparooService = ZaparooService(settings: settings)

        _settings = StateObject(wrappedValue: settings)
        _zaparooService = StateObject(wrappedValue: zaparooService)
    }

    var body: some View {
        Group {
            // Show main view if connected OR if we're reconnecting after being connected
            // This prevents jarring view switch during auto-reconnect
            if zaparooService.connectionState == .connected ||
               (hasConnectedBefore && (zaparooService.connectionState == .connecting || zaparooService.connectionState == .disconnected)) {
                #if DEBUG
                // Debug builds: Check for launch argument to force Consumer UI
                // Usage: Add "-ForceConsumerUI" to scheme arguments in Xcode
                if ProcessInfo.processInfo.arguments.contains("-ForceConsumerUI") {
                    ConsumerView(zaparooService: zaparooService, settings: settings)
                } else {
                    // Default: Show full debug UI with all panels
                    DebugContentView(zaparooService: zaparooService, settings: settings)
                }
                #else
                // Release builds: Show consumer chat UI
                ConsumerView(zaparooService: zaparooService, settings: settings)
                #endif
            } else {
                ConnectionView(zaparooService: zaparooService, settings: settings)
            }
        }
        .onChange(of: zaparooService.connectionState) { oldState, newState in
            // Track successful connection for smooth reconnection UX
            if case .connected = newState {
                hasConnectedBefore = true
            }

            // Handle intentional disconnect - return to connection screen
            // Intentional disconnect: .connected → .disconnected (user clicked disconnect button)
            // Unexpected disconnect: .connected → .connecting (auto-reconnect kicks in immediately)
            if case .disconnected = newState, case .connected = oldState {
                AppLogger.standard("🔌 Intentional disconnect detected - returning to connection screen")
                hasConnectedBefore = false  // Reset flag to allow navigation back to ConnectionView
                zaparooService.clearPendingCommands()
            }

            // Handle reconnection failure after max attempts - return to connection screen
            if case .error(let errorMessage) = newState {
                if errorMessage.contains("failed after") {
                    AppLogger.standard("❌ Reconnection failed - returning to connection screen")
                    hasConnectedBefore = false
                    zaparooService.clearPendingCommands()
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - Scene Phase Lifecycle Management

    /// Handle app lifecycle transitions for battery optimization
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            // App backgrounded (screen lock, home button, or app switcher)
            // Strategy: Keep connection alive for 2 minutes for quick return, then disconnect
            // This works for BOTH screen lock and home button - simpler and more reliable

            AppLogger.standard("📱 App backgrounded - will disconnect after \(Int(inactivityDisconnectDelay))s if not resumed")

            // End session immediately when user leaves the app
            Task { @MainActor in
                await CloudflareService.shared.endSession()
            }

            // Perform full teardown of audio services to prevent crashes during reconnection
            NotificationCenter.default.post(name: Notification.Name("AppEnteringBackground"), object: nil)

            // Start inactivity timer - disconnect if we stay backgrounded for 2+ minutes
            startInactivityDisconnectTimer()

        case .inactive:
            // Screen locked or app switching - pause recording but keep everything ready
            AppLogger.standard("📱 App becoming inactive (screen lock or app switcher)")

            // Cancel any pending disconnect timer - we'll start a fresh one if we go to .background
            cancelInactivityDisconnectTimer()

            // Stop any active recording and mute hot mic
            NotificationCenter.default.post(name: Notification.Name("AppBecomingInactive"), object: nil)

        case .active:
            // App came back to foreground - reconnect services if needed
            AppLogger.standard("📱 App becoming active - resuming services")

            // Cancel inactivity disconnect timer - user is back!
            cancelInactivityDisconnectTimer()

            // Restart session tracking
            CloudflareService.shared.restartSession()

            // Reconnect WebSocket if disconnected OR if connection failed
            // This handles both clean disconnect (.disconnected) and error states (.error)
            if !settings.misterIPAddress.isEmpty {
                switch zaparooService.connectionState {
                case .disconnected, .error:
                    AppLogger.standard("🔄 Auto-reconnecting to MiSTer at \(settings.misterIPAddress)")
                    zaparooService.connect(to: settings.misterIPAddress)
                case .connected:
                    AppLogger.verbose("Already connected to MiSTer")
                case .connecting:
                    AppLogger.verbose("Already connecting to MiSTer")
                }
            }

            // Notify SpeechService to restart/unmute hot mic
            NotificationCenter.default.post(name: Notification.Name("AppBecomingActive"), object: nil)

        @unknown default:
            AppLogger.standard("⚠️ Unknown scene phase: \(newPhase)")
            break
        }
    }

    // MARK: - Inactivity Timer Management

    /// Start timer to disconnect after extended inactivity (battery optimization)
    private func startInactivityDisconnectTimer() {
        // Cancel any existing timer first
        cancelInactivityDisconnectTimer()

        AppLogger.standard("⏱️ Starting inactivity disconnect timer (\(Int(inactivityDisconnectDelay))s)")

        inactivityDisconnectTimer = Timer.scheduledTimer(withTimeInterval: inactivityDisconnectDelay, repeats: false) { [weak zaparooService] _ in
            AppLogger.standard("⏰ Inactivity timeout reached - disconnecting for battery savings")

            let taskID = UIApplication.shared.beginBackgroundTask {
                AppLogger.standard("⏰ Background task time expired during inactivity disconnect")
            }

            // Full teardown after extended inactivity (session already ended in .background handler)
            Task { @MainActor in
                zaparooService?.disconnect()

                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                }
            }
        }
    }

    /// Cancel inactivity disconnect timer
    private func cancelInactivityDisconnectTimer() {
        if inactivityDisconnectTimer != nil {
            AppLogger.verbose("⏱️ Cancelling inactivity disconnect timer")
            inactivityDisconnectTimer?.invalidate()
            inactivityDisconnectTimer = nil
        }
    }
}

#Preview {
    MainAppView()
}
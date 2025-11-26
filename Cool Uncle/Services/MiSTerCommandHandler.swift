import SwiftUI

/// Unified MiSTer command handling service
/// Handles all ZaparooService responses (launch, search, systems) for both DebugContentView and ConsumerView
/// This ensures consistent behavior and eliminates code duplication
@MainActor
class MiSTerCommandHandler: ObservableObject {

    // MARK: - Dependencies (weak to avoid retain cycles)

    weak var enhancedOpenAIService: EnhancedOpenAIService?
    weak var ttsService: AVSpeechService?
    weak var zaparooService: ZaparooService?
    weak var speechService: SpeechService?
    weak var uiStateService: UIStateService?
    var settings: AppSettings?
    var currentGameService: CurrentGameService = CurrentGameService.shared

    // MARK: - State

    @Published var pendingLaunchInfo: (command: String, gameName: String)? = nil
    @Published var awaitingRandomGameLaunch: Bool = false
    var lastProcessedRandomGame: String? = nil
    var pendingRandomGameRequest: String? = nil
    var launchTimeoutTimer: Timer? = nil

    // MARK: - Delegate Closures (for view-specific behavior)

    /// Called when a message should be added to conversation history (DebugContentView)
    var onAddConversationMessage: ((ChatMessage) -> Void)?

    /// Called when a chat bubble should be added (ConsumerView)
    var onAddChatBubble: ((String) -> Void)?

    // MARK: - Setup

    func setup(
        enhancedOpenAI: EnhancedOpenAIService,
        tts: AVSpeechService,
        zaparoo: ZaparooService,
        speech: SpeechService,
        settings: AppSettings,
        uiState: UIStateService? = nil
    ) {
        self.enhancedOpenAIService = enhancedOpenAI
        self.ttsService = tts
        self.zaparooService = zaparoo
        self.speechService = speech
        self.settings = settings
        self.uiStateService = uiState
    }

    // MARK: - Main Entry Point

    /// Send command to MiSTer and handle the result
    func sendCommand(_ command: String, userMessage: String? = nil) {
        zaparooService?.sendJSONCommand(command) { result in
            Task { @MainActor in
                self.handleCommandResult(result, command: command, userMessage: userMessage)
            }
        }
    }

    /// Handle command result from ZaparooService
    func handleCommandResult(_ result: Result<ZaparooResponse, Error>, command: String, userMessage: String? = nil) {
        // Use verbose logging for internal command routing details
        AppLogger.verbose("🚀 HANDLE COMMAND RESULT: Processing result for command")

        switch result {
        case .success(let response):
            AppLogger.verbose("🚀 HANDLE COMMAND RESULT SUCCESS: \(response)")

            // Process different command types
            if let commandData = command.data(using: .utf8),
               let commandDict = try? JSONSerialization.jsonObject(with: commandData) as? [String: Any],
               let method = commandDict["method"] as? String {

                if method == "launch" {
                    handleLaunchCommand(commandDict: commandDict, userMessage: userMessage)
                } else if method == "media.search" {
                    handleSearchCommand(response: response)
                }
            }

        case .failure(let error):
            AppLogger.emit(type: .error, content: "Failed to send command: \(error.localizedDescription)")
        }
    }

    // MARK: - Launch Command Handling

    private func handleLaunchCommand(commandDict: [String: Any], userMessage: String?) {
        AppLogger.verbose("🚀 HANDLE COMMAND RESULT: Processing LAUNCH command result")

        // FIXED: ALL launch commands return NULL initially - this is normal WebSocket behavior
        // Wait for media.started notification to confirm actual success

        // Extract launch information for timeout handling
        let params = commandDict["params"] as? [String: Any]
        let launchText = params?["text"] as? String ?? ""
        let gameName = extractGameNameFromLaunch(commandDict)

        // Skip timeout logic for input commands (they don't generate media.started events)
        if launchText.hasPrefix("**input.") {
            AppLogger.standard("ℹ️ INPUT COMMAND: Skipping timeout for utility command: \(launchText)")
            self.pendingLaunchInfo = nil
            self.launchTimeoutTimer?.invalidate()
        } else {
            // Store pending launch info for timeout handling (game launches only)
            self.pendingLaunchInfo = (command: commandDict.description, gameName: gameName)

            // Set timeout timer for actual launch failures
            self.launchTimeoutTimer?.invalidate()
            // Random launches can legitimately take longer to emit media.started on MiSTer
            let isRandomLaunch = launchText.contains("**launch.random:")
            let timeoutSeconds: TimeInterval = isRandomLaunch ? 8.0 : 3.0
            self.launchTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
                guard let self = self else { return }

                Task { @MainActor in
                    // Only show error if no media.started was received
                    if self.pendingLaunchInfo != nil {
                        // Check if this was a random launch for appropriate error message
                        let errorMessage = isRandomLaunch
                            ? "I couldn't launch a random game. The system might be unavailable or have no games."
                            : "I couldn't launch \(gameName). The game file might be missing or the path might be invalid."

                        AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(errorMessage)' via MiSTerCommandHandler LAUNCH_TIMEOUT - Game: \(gameName)")
                        self.enhancedOpenAIService?.coolUncleResponse = errorMessage

                        // Notify views
                        self.onAddConversationMessage?(ChatMessage(role: "assistant", content: errorMessage))
                        self.onAddChatBubble?(errorMessage)

                        // Clear the "Searching..." status on timeout
                        self.uiStateService?.hideStatus()

                        self.pendingLaunchInfo = nil
                        AppLogger.emit(type: .debug, content: "⏱️ TIMING: LAUNCH_TIMEOUT_TRIGGERED at \(Date().timeIntervalSince1970) for game: \(gameName)")
                        AppLogger.emit(type: .error, content: "LAUNCH TIMEOUT: No media.started received for \(gameName)")
                    }
                }
            }
        }

        // Handle random launches - set flag for GameActuallyLaunched handler
        if launchText.contains("**launch.random:") && launchText.hasSuffix("/*") {
            AppLogger.emit(type: .standard, content: "🎲 Random launch detected, setting awaitingRandomGameLaunch = true")
            self.awaitingRandomGameLaunch = true
            self.pendingRandomGameRequest = userMessage ?? "Play a random game"
        }

        AppLogger.verbose("🚀 Launch command sent, waiting for media.started confirmation")
        AppLogger.emit(type: .debug, content: "⏱️ TIMING: LAUNCH_COMMAND_SENT at \(Date().timeIntervalSince1970)")

        // Track successful game launches for sentiment analysis
        self.trackGameLaunch(from: commandDict.description)
    }

    // MARK: - Search Command Handling

    private func handleSearchCommand(response: ZaparooResponse) {
        // Handle search results - send back to AI for launch command generation
        if let result = response.result,
           let results = result["results"] as? [[String: Any]] {

            // Check if this is an optimized search that can handle zero results gracefully
            let actionType = enhancedOpenAIService?.threeCallContext?.actionType
            let isOptimizedSearch = (enhancedOpenAIService?.isUsingOptimizedSearch ?? false) ||
                actionType == "launch_specific" ||
                actionType == "launch_specific_exact"

            if results.isEmpty && !isOptimizedSearch {
                // Zero results for NON-optimized search - generate immediate error response
                AppLogger.standard("🔍 Search returned 0 results - generating no results response (non-optimized search)")

                // Generate appropriate response for no results
                let noResultsMessage = "I couldn't find any games matching your request. Try being more specific or asking for a different game."

                AppLogger.emit(type: .debug, content: "🔧 NO_GAMES_MESSAGE: '\(noResultsMessage)' via MiSTerCommandHandler SEARCH_ZERO_RESULTS_LEGACY")

                // Notify views
                onAddConversationMessage?(ChatMessage(role: "assistant", content: noResultsMessage))
                onAddChatBubble?(noResultsMessage)

                // Speak the response
                ttsService?.speak(noResultsMessage, voice: settings?.selectedVoice)

            } else if results.isEmpty && isOptimizedSearch {
                // Zero results for optimized search - must still resume continuation
                AppLogger.standard("🔍 Processing 0 search results for AI")

                // CRITICAL: Must call captureSearchResult to resume the waiting continuation
                // Even with zero results, the 3-search batch needs to know this search completed
                // Without this, the continuation never resumes and guard timer expires
                if let result = response.result {
                    let responseID = response.id ?? "unknown"
                    enhancedOpenAIService?.captureSearchResult(result, searchID: responseID)
                }

            } else {
                AppLogger.standard("🔍 Processing \(results.count) search results for AI")

                // Gate search results to appropriate path based on optimized search flag and action type
                if let result = response.result {

                    // Extract search ID from response and validate
                    let responseID = response.id ?? "unknown"

                    // Check if this result belongs to an active search batch
                    let isActiveSearch = enhancedOpenAIService?.isSearchInActiveBatch(responseID) ?? false

                    if !isActiveSearch {
                        // Not in active batch - could be YOLO search or abandoned search
                        // YOLO searches don't get added to batch, so they'll fail this check
                        // Let it through - searchResultManager will handle via direct continuation
                        AppLogger.verbose("⏰ Search result not in active batch (may be YOLO or late): \(responseID)")
                    } else {
                        AppLogger.verbose("✅ Search result validated: \(responseID) is in active batch")
                    }

                    let actionType = enhancedOpenAIService?.threeCallContext?.actionType

                    // launch_specific ALWAYS uses optimized path, even for late results
                    if (enhancedOpenAIService?.isUsingOptimizedSearch ?? false) ||
                       actionType == "launch_specific" ||
                       actionType == "launch_specific_exact" ||
                       actionType == "recommend" ||
                       actionType == "recommend_alternative" ||
                       actionType == "recommend_confirm" {
                        // ONLY feed optimized path
                        enhancedOpenAIService?.captureSearchResult(result, searchID: responseID)
                    } else {
                        // ONLY feed old path (should rarely/never happen now)
                        AppLogger.standard("⚠️ WARNING: Falling back to legacy search handler")
                        AppLogger.standard("   ActionType: \(actionType ?? "nil")")
                        // Legacy path would need to be handled by the view - but this should not happen
                    }
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func extractGameNameFromLaunch(_ commandDict: [String: Any]) -> String {
        if let params = commandDict["params"] as? [String: Any],
           let text = params["text"] as? String {
            // Extract game name from path (e.g., "SNES/Super Metroid.sfc" → "Super Metroid")
            let components = text.components(separatedBy: "/")
            let filename = components.last ?? text

            // Remove known game file extensions (preserve game names with periods like "Street Fighter II")
            let gameExtensions = [".zip", ".sfc", ".smc", ".md", ".gen", ".nes", ".gb", ".gbc", ".gba",
                                 ".pce", ".ngp", ".ws", ".col", ".sg", ".msx", ".vb", ".gg", ".sms",
                                 ".bin", ".cue", ".chd", ".pbp", ".cdi", ".gdi", ".iso"]

            var nameWithoutExtension = filename
            for fileExtension in gameExtensions {
                if filename.lowercased().hasSuffix(fileExtension) {
                    nameWithoutExtension = String(filename.dropLast(fileExtension.count))
                    break
                }
            }

            return nameWithoutExtension
        }
        return "the game"
    }

    private func trackGameLaunch(from jsonCommand: String) {
        // Extract game name from launch command for sentiment tracking
        if let data = jsonCommand.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let params = json["params"] as? [String: Any],
           let text = params["text"] as? String {

            // Don't extract game name for random launches - wait for actual game notification
            if text.contains("launch.random:") {
                AppLogger.gameHistory("🎲 Skipping extraction for random launch, waiting for actual game...")
                return
            }

            // Don't extract game name from launch path - causes duplicate entries
            // Wait for media.started notification to get the accurate game name
            AppLogger.gameHistory("🎯 Launch command sent - waiting for media.started for accurate game name")
        }
    }

    // MARK: - Game State Management

    /// Update current game state when a game actually launches
    /// Should be called from GameActuallyLaunched notification handler
    func updateCurrentGameState(
        gameName: String,
        systemName: String?,
        launchCommand: String?,
        mediaPath: String?
    ) {
        // Update the current game service
        currentGameService.updateCurrentGame(
            name: gameName,
            system: systemName,
            mediaPath: mediaPath,
            launchCommand: launchCommand
        )

        // Clear previous search context when new game launches (prevents stale follow-up context)
        enhancedOpenAIService?.threeCallContext?.targetGame = nil
        enhancedOpenAIService?.threeCallContext?.lastSearchSystem = nil
    }
}

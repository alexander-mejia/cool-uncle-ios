import SwiftUI

/// Consumer-facing chat UI for Cool Uncle
/// Features:
/// - Chat bubble conversation history
/// - iMessage-style transient status
/// - Large mic button with timer ring
/// - Full-screen keyboard wipe animation
/// - Manual text input toggle
struct ConsumerView: View {
    // MARK: - Services

    @StateObject private var speechService = SpeechService()
    @StateObject private var enhancedOpenAIService = EnhancedOpenAIService()
    @StateObject private var ttsService = AVSpeechService()
    @StateObject private var uiStateService = UIStateService()
    @StateObject private var chatBubbleService = ChatBubbleService()
    @StateObject private var feedbackService = WakeWordFeedbackService()
    @StateObject private var commandHandler = MiSTerCommandHandler()

    @ObservedObject var zaparooService: ZaparooService
    @ObservedObject var settings: AppSettings

    // MARK: - UI State

    @State private var showingSettings = false
    @State private var showingGameHistory = false
    @State private var showingBugReport = false
    @State private var conversationHistory: [ChatMessage] = []
    @State private var textInput = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isKeyboardOverlayVisible = false
    @State private var showWakeModeAlert = false

    // Debounce tracking to prevent button spam race conditions
    @State private var lastButtonReleaseTime: TimeInterval = 0

    // MARK: - Body

    var body: some View {
        // Set speech completion handler (inline in body, guaranteed to run)
        // This ensures both PTT and wake word trigger sendToOpenAI after recording
        let _ = speechService.setSpeechCompletionHandler {
            self.sendToOpenAI()
        }

        ZStack {
            // LAYER 1: Main content
            VStack(spacing: 0) {
                // Chat bubble scroll view
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            // Persistent chat bubbles
                            ForEach(chatBubbleService.bubbles) { bubble in
                                ChatBubbleView(bubble: bubble, onRetry: handleRetry)
                                    .id(bubble.id)
                            }

                            // Real-time transcription bubble (shown while speaking AND processing)
                            // Keep showing during isProcessing so bubble doesn't disappear while waiting for final result
                            if !speechService.displayTranscription.isEmpty && (speechService.isRecording || speechService.isProcessing) {
                                HStack(alignment: .bottom, spacing: 0) {
                                    Spacer(minLength: 60)  // Space on left for user bubble
                                    Text(speechService.displayTranscription)
                                        .font(.body)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .padding(.bottom, 12)  // Extra bottom padding for tail space (matches tailHeight)
                                        .foregroundColor(.white)
                                        .frame(maxWidth: 280)  // Match bubble width constraint
                                        .background(
                                            BubbleTailShape(isUserBubble: true)
                                                .fill(Color.blue.opacity(0.7))  // Slightly transparent to show it's in-progress
                                        )
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 2)
                                .id("realtime_transcription")
                            }

                            // Transient status (pulsing grey text)
                            if let status = uiStateService.transientStatus {
                                TransientStatusView(status: status)
                                    .padding(.vertical, 8)
                                    .id("transient_status")
                            }

                            // Report Issue button - only show after assistant has responded
                            if chatBubbleService.bubbles.contains(where: { $0.role == .assistant }) {
                                Button(action: {
                                    showingBugReport = true
                                }) {
                                    Text("Report an issue with this response")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                                .id("report_issue_button")
                            }
                        }
                        .padding(.top, 0)
                        .padding(.bottom, 0)
                    }
                    .onChange(of: chatBubbleService.bubbles.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: uiStateService.transientStatus) { _, newStatus in
                        if newStatus != nil {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: speechService.displayTranscription) { _, _ in
                        // Auto-scroll when transcription updates
                        if speechService.isRecording {
                            scrollToBottom(proxy)
                        }
                    }
                }

                Spacer()

                // Input area - hidden when keyboard overlay is visible
                if !isKeyboardOverlayVisible {
                    VStack(spacing: 6) {
                        // Wake word toggle
                        Toggle("Hands Free \"Hey Mister\"", isOn: $speechService.isWakeWordEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                            .frame(maxWidth: 300)

                        // Prompt text
                        Text(promptText)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Large mic button with timer ring
                        MicButtonView(
                            speechService: speechService,
                            uiStateService: uiStateService,
                            onMicTap: handleMicTap,
                            onMicPress: handleMicPress
                        )

                        // Persistent text input bar (tap to activate)
                        HStack(spacing: 12) {
                            // Tappable area that opens keyboard overlay (matches real text field styling exactly)
                            Button(action: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    isKeyboardOverlayVisible = true
                                }
                            }) {
                                HStack {
                                    Text("Type a message...")
                                        .foregroundColor(.secondary)
                                        .font(.body)
                                    Spacer()
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 7)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            // Send button placeholder (disabled, matches real button)
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.gray)

                            // Chevron down button (matches dismiss button in overlay)
                            Button(action: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    isKeyboardOverlayVisible = true
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 28))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 8)
                }

                Divider()

                // Bottom tab bar
                HStack(spacing: 0) {
                    // Disconnect button
                    Button(action: {
                        zaparooService.disconnect()
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "wifi.slash")
                                .font(.title2)
                            Text("Disconnect")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Game History button
                    Button(action: {
                        showingGameHistory = true
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title2)
                            Text("History")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Settings button
                    Button(action: { showingSettings = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "gear")
                                .font(.title2)
                            Text("Settings")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // F12 Menu
                    Button(action: {
                        sendF12Command()
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "keyboard")
                                .font(.title2)
                            Text("F12")
                                .font(.caption)
                        }
                        .foregroundColor(zaparooService.connectionState == .connected ? .orange : .gray)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 60)
                .background(Color(.systemGray6))
            }

            // LAYER 2: Keyboard overlay - slides up from bottom, only darkens non-chat area
            if isKeyboardOverlayVisible {
                VStack(spacing: 0) {
                    // Transparent spacer that allows taps to pass through to chat ScrollView
                    Color.clear
                        .allowsHitTesting(false)

                    // Keyboard input area (captures taps/interactions)
                    VStack(spacing: 0) {
                        Divider()

                        // Text input bar
                        HStack(spacing: 12) {
                            TextField("Type a message...", text: $textInput)
                                .textFieldStyle(.roundedBorder)
                                .focused($isTextFieldFocused)
                                .onSubmit {
                                    sendTextMessage()
                                }

                            // Send button (iMessage-style blue arrow)
                            Button(action: {
                                sendTextMessage()
                            }) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(textInput.isEmpty ? .gray : .blue)
                            }
                            .disabled(textInput.isEmpty)

                            // Dismiss keyboard button (chevron down)
                            Button(action: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    isKeyboardOverlayVisible = false
                                    isTextFieldFocused = false
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 28))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color(.systemBackground))
                    }
                    .background(Color.black.opacity(0.3))  // Only darken bottom portion (below keyboard)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    // Auto-focus text field when overlay appears
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isTextFieldFocused = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: settings)
        }
        .sheet(isPresented: $showingGameHistory) {
            GamePreferenceView()
        }
        .sheet(isPresented: $showingBugReport) {
            BugReportView(
                zaparooService: zaparooService,
                settings: settings,
                enhancedOpenAIService: enhancedOpenAIService,
                speechService: speechService,
                lastTranscription: speechService.transcription
            )
        }
        .alert("Screen Will Stay On", isPresented: $showWakeModeAlert) {
            Button("Got it", role: .cancel) {
                settings.hasSeenWakeModeSleepAlert = true
            }
        } message: {
            Text("When this switch is on, the device won't go to sleep automatically. You'll need to sleep the phone yourself or switch out of the app.")
        }
        .alert("OpenAI API Key Error", isPresented: $enhancedOpenAIService.showAPIKeyError) {
            Button("Open Settings") {
                showingSettings = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("There's a problem with your OpenAI API key. Please check that it's entered correctly in Settings, and that your OpenAI account has available credits.")
        }
        .onChange(of: speechService.isWakeWordEnabled) { _, newValue in
            // Show alert on first enable if user hasn't seen it before
            if newValue && !settings.hasSeenWakeModeSleepAlert {
                showWakeModeAlert = true
            }
        }
        .onChange(of: enhancedOpenAIService.coolUncleResponse) { oldResponse, newResponse in
            // Auto-speak new AI responses when they appear
            if !newResponse.isEmpty && newResponse != oldResponse {
                // Check if this is a process chatter response that should be suppressed
                let suppressedPhrases = [
                    "let me find",
                    "let me search",
                    "what about",
                    "i'll look for",
                    "the best version found",
                    "let me launch"
                ]

                let shouldSuppress = suppressedPhrases.contains { phrase in
                    newResponse.lowercased().contains(phrase)
                }

                if shouldSuppress {
                    AppLogger.verbose("Suppressing process chatter: \(newResponse)")
                } else {
                    AppLogger.aiResponse(newResponse)
                    ttsService.speak(newResponse, voice: settings.selectedVoice)
                }
            }
        }
        .onChange(of: zaparooService.connectionState) { oldState, newState in
            // Handle MiSTer disconnection - cancel searches to prevent stuck state
            if case .connected = oldState {
                // Connection was lost - clean up and inform user
                if case .connecting = newState {
                    // Unexpected disconnect - auto-reconnecting
                    AppLogger.standard("🔌 Connection lost - cleaning up active searches, auto-reconnecting...")
                    enhancedOpenAIService.handleDisconnection()
                    speechService.resetToIdle()

                    let reconnectMessage = "Lost connection to MiSTer. Reconnecting..."
                    chatBubbleService.addAssistantMessage(reconnectMessage)
                    ttsService.speak(reconnectMessage, voice: settings.selectedVoice)

                } else if case .disconnected = newState {
                    // Intentional disconnect
                    AppLogger.standard("🔌 Intentional disconnect - cleaning up")
                    enhancedOpenAIService.handleDisconnection()
                    speechService.resetToIdle()
                }
            }

            // Handle reconnection success
            if case .connected = newState, case .connecting = oldState {
                let reconnectedMessage = "Reconnected to MiSTer!"
                chatBubbleService.addAssistantMessage(reconnectedMessage)
                ttsService.speak(reconnectedMessage, voice: settings.selectedVoice)
            }
        }
        .onAppear {
            // Wire up delegation between CallCDispatchService and SentimentAnalysisService
            CallCDispatchService.shared.setDelegate(SentimentAnalysisService.shared, apiKey: settings.openAIAPIKey)
            CallCDispatchService.shared.setOpenAIService(enhancedOpenAIService)
            AppLogger.standard("🔗 CallCDispatchService delegation wired up to SentimentAnalysisService + EnhancedOpenAIService")

            // Inject services into EnhancedOpenAIService
            enhancedOpenAIService.setUIStateService(uiStateService)
            enhancedOpenAIService.setChatBubbleService(chatBubbleService)

            // Setup unified MiSTer command handler
            commandHandler.setup(
                enhancedOpenAI: enhancedOpenAIService,
                tts: ttsService,
                zaparoo: zaparooService,
                speech: speechService,
                settings: settings,
                uiState: uiStateService
            )
            commandHandler.onAddChatBubble = { message in
                self.chatBubbleService.addAssistantMessage(message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GameActuallyLaunched"))) { notification in
            // Always cancel any pending launch timeout as soon as we receive the signal
            self.commandHandler.launchTimeoutTimer?.invalidate()
            self.commandHandler.pendingLaunchInfo = nil

            let notifiedGameName = notification.userInfo?["gameName"] as? String
            if let gameName = notifiedGameName {
                AppLogger.gameHistory("🎮 Received actual game launch: \(gameName)")

                // Add action bubble with the ACTUAL game name that was launched
                // This is especially important for random launches where we don't know the game name upfront
                chatBubbleService.addActionMessage(gameName)

                // Clear any pending recommendation cache - new game launched
                if enhancedOpenAIService.isPendingRecommendationValid() {
                    AppLogger.gameHistory("🔄 CACHE CLEAR: New game launched, clearing stale recommendation cache")
                    enhancedOpenAIService.clearPendingRecommendation()
                }

                // Extract launch command and system info if available
                let launchCommand = notification.userInfo?["launchCommand"] as? String
                let systemName = notification.userInfo?["systemName"] as? String
                let mediaPath = notification.userInfo?["mediaPath"] as? String

                // Update current game state via unified handler
                self.commandHandler.updateCurrentGameState(
                    gameName: gameName,
                    systemName: systemName,
                    launchCommand: launchCommand,
                    mediaPath: mediaPath
                )

                // Update enhanced OpenAI service with actual game name for ALL launches
                self.enhancedOpenAIService.updateCommandExecutionResult("Command executed successfully", actualGameName: gameName)

                // Complete any pending deferred response for ALL game launches
                Task {
                    await self.enhancedOpenAIService.completeDeferredResponse(actualGameName: gameName)
                }

                // Check if this was a random launch needing Cool Uncle response
                if self.commandHandler.awaitingRandomGameLaunch &&
                   self.commandHandler.lastProcessedRandomGame != gameName &&
                   self.enhancedOpenAIService.threeCallContext?.actionType == "random" {
                    AppLogger.gameHistory("🎲 Processing random game launch: \(gameName)")

                    Task { @MainActor in
                        await self.enhancedOpenAIService.handleRandomGameLaunch(
                            gameName: gameName,
                            userMessage: self.commandHandler.pendingRandomGameRequest ?? "Play a random game",
                            conversationHistory: Array(conversationHistory),
                            apiKey: self.settings.openAIAPIKey
                        )
                    }

                    self.commandHandler.awaitingRandomGameLaunch = false
                    self.commandHandler.lastProcessedRandomGame = gameName
                }
            } else {
                AppLogger.emit(type: .debug, content: "📣 GameActuallyLaunched received without gameName — timeout cleared")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LaunchGameFromPreferences"))) { notification in
            if let launchCommand = notification.userInfo?["launchCommand"] as? String,
               let gameName = notification.userInfo?["gameName"] as? String {
                AppLogger.gameHistory("🎮 Launching game from preferences: \(gameName)")
                self.sendCommandToMiSTer(launchCommand, userMessage: "Launch \(gameName)")
            }
        }
    }

    // MARK: - Helper Methods

    private var promptText: String {
        if speechService.isWakeWordEnabled {
            return "Tap or say \"Hey Mister\" to start"
        } else {
            return "Hold to talk"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Priority: real-time transcription > transient status > last bubble
        if speechService.isRecording && !speechService.displayTranscription.isEmpty {
            withAnimation {
                proxy.scrollTo("realtime_transcription", anchor: .bottom)
            }
        } else if uiStateService.transientStatus != nil {
            withAnimation {
                proxy.scrollTo("transient_status", anchor: .bottom)
            }
        } else if let lastBubble = chatBubbleService.bubbles.last {
            withAnimation {
                proxy.scrollTo(lastBubble.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Handlers

    private func handleMicTap() {
        switch speechService.recordingState {
        case .recordingWake:
            // STOP button tapped during wake word recording
            speechService.stopRecording()
            AppLogger.standard("🛑 User manually stopped wake word recording")

        case .processingRequest:
            // RED STOP button tapped during AI processing - cancel the request
            AppLogger.standard("🛑 User cancelled AI request")

            // Cancel ongoing AI processing
            enhancedOpenAIService.cancel()

            // Stop any TTS that might be playing
            ttsService.stopSpeaking()

            // Add "Request stopped" bubble to chat
            chatBubbleService.addCancellationMessage()

            // Reset speech service state back to idle
            speechService.resetToIdle()

        case .idle, .recordingPTT:
            // Button tap during idle or PTT mode - no action
            break
        }
    }

    private func handleMicPress(_ isPressing: Bool) {
        if isPressing {
            // Button pressed down

            // Debounce: Ignore presses within 150ms of previous release
            // Prevents button spam from creating overlapping recording sessions
            let now = Date().timeIntervalSince1970
            if now - lastButtonReleaseTime < 0.15 {
                AppLogger.verbose("🎤 Button press debounced (\(Int((now - lastButtonReleaseTime) * 1000))ms too soon)")
                return
            }

            if speechService.recordingState == .idle {
                // Start PTT recording
                ttsService.stopSpeaking()
                speechService.startRecording()
            }
        } else {
            // Button released

            // Track release time for debounce
            lastButtonReleaseTime = Date().timeIntervalSince1970

            if speechService.recordingState == .recordingPTT {
                // Stop PTT recording
                speechService.stopRecording()
            }
        }
    }

    private func sendTextMessage() {
        guard !textInput.isEmpty else { return }

        // Add user bubble
        chatBubbleService.addUserMessage(textInput)

        // CRITICAL: Clean speech recognition state before manual text input
        // Manual text bypasses normal speech flow, which can leave recognition
        // components in inconsistent state. This causes subsequent PTT to fail
        // with "No speech detected" error even though mic works fine.
        // See: Bug report 2025-01-23 - PTT failure after manual text input
        speechService.prepareForManualTextInput()

        // Set transcription (bypass speech recognition)
        speechService.transcription = textInput
        textInput = ""

        // Set state to processingRequest so button shows RED STOP during AI processing
        // This allows user to cancel manual text requests just like voice requests
        speechService.recordingState = .processingRequest

        // Trigger AI flow
        sendToOpenAI()

        // Dismiss keyboard overlay and focus
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isKeyboardOverlayVisible = false
        }
        isTextFieldFocused = false
    }

    private func sendToOpenAI() {
        guard !speechService.transcription.isEmpty else { return }

        // Reset cancellation state for new request
        // This allows user to issue new commands immediately after pressing STOP
        enhancedOpenAIService.resetCancellationState()

        // Log the user's voice input
        AppLogger.userInput("\"\(speechService.transcription)\"")

        // Add user bubble (if not already added by text input)
        if chatBubbleService.bubbles.last?.content != speechService.transcription {
            chatBubbleService.addUserMessage(speechService.transcription)
        }

        // Create game context snapshot (CRITICAL: Must be BEFORE AI processing)
        let gameContextSnapshot: GameContextSnapshot = {
            if CurrentGameService.shared.currentGameName == nil,
               let stopSnapshot = enhancedOpenAIService.getLastStopGameSnapshot(),
               enhancedOpenAIService.isStopGameContextValid() {
                AppLogger.gameHistory("🔄 Restoring stopped game context: \(stopSnapshot.sentimentTargetGame)")
                return stopSnapshot
            } else {
                return CurrentGameService.shared.createGameContextSnapshot(
                    forUserMessage: speechService.transcription
                )
            }
        }()

        AppLogger.gameHistory("🎯 Captured context BEFORE AI: Current game = \(gameContextSnapshot.currentGame ?? "None")")

        // Create user message
        let userMessage = ChatMessage(role: "user", content: speechService.transcription)
        let capturedUserMessage = speechService.transcription

        Task {
            // Process with EnhancedOpenAIService (3-call architecture)
            // See three-call-architecture.md for details
            await enhancedOpenAIService.processUserMessage(
                userMessage: capturedUserMessage,
                conversationHistory: Array(conversationHistory),
                availableSystems: zaparooService.availableSystems,
                gameContextSnapshot: gameContextSnapshot,
                preservedActionType: nil,
                apiKey: settings.openAIAPIKey,
                onCommandGenerated: { command in
                    Task { @MainActor in
                        AppLogger.standard("🎯 Command generated: \(command)")
                        self.sendCommandToMiSTer(command, userMessage: capturedUserMessage)
                    }
                },
                onCommandExecuted: { result in
                    Task { @MainActor in
                        AppLogger.standard("✅ Command executed: \(result)")
                    }
                }
            )

            // Add to conversation history
            conversationHistory.append(userMessage)

            if !enhancedOpenAIService.coolUncleResponse.isEmpty {
                let assistantMessage = ChatMessage(role: "assistant", content: enhancedOpenAIService.coolUncleResponse)
                conversationHistory.append(assistantMessage)
            }

            // CRITICAL: Reset state back to idle after AI processing completes
            // This allows the button to return to blue (ready for next request)
            speechService.resetToIdle()
        }
    }

    private func sendCommandToMiSTer(_ command: String, userMessage: String) {
        // CHOKEPOINT 2: Last line of defense - block command if user pressed STOP
        // This catches edge cases where command was generated right before cancellation
        guard !enhancedOpenAIService.isCancellationRequested else {
            AppLogger.standard("🛑 CHOKEPOINT 2: MiSTer command cancelled - user pressed STOP")
            enhancedOpenAIService.resetCancellationState()
            return
        }

        // Parse the command to determine the appropriate method to call
        guard let commandData = command.data(using: .utf8),
              let commandDict = try? JSONSerialization.jsonObject(with: commandData) as? [String: Any],
              let method = commandDict["method"] as? String else {
            AppLogger.emit(type: .error, content: "Failed to parse command: \(command)")
            return
        }

        // Action bubble will be added when GameActuallyLaunched notification arrives with real game name
        // This ensures we show the actual game that was launched (especially important for random launches)

        // Route to appropriate ZaparooService method to maintain proper state tracking
        switch method {
        case "launch":
            if let params = commandDict["params"] as? [String: Any],
               let text = params["text"] as? String {
                AppLogger.verbose("🚀 LAUNCH COMMAND ROUTING: Sending to ZaparooService.launchGame(text: \"\(text)\")")
                zaparooService.launchGame(text: text) { result in
                    AppLogger.verbose("🚀 LAUNCH COMMAND CALLBACK: Received result from ZaparooService")
                    self.commandHandler.handleCommandResult(result, command: command, userMessage: userMessage)
                }
            } else {
                AppLogger.emit(type: .error, content: "LAUNCH COMMAND ERROR: Failed to extract 'text' parameter from command")
            }
        case "media.search":
            if let params = commandDict["params"] as? [String: Any],
               let query = params["query"] as? String {
                let systems = params["systems"] as? [String] ?? []

                // Extract original ID to preserve batch tracking
                let originalId = commandDict["id"] as? String

                zaparooService.searchMedia(query: query, systems: systems, preserveId: originalId) { result in
                    self.commandHandler.handleCommandResult(result, command: command)
                }
            }
        case "stop":
            zaparooService.stopCurrentGame { result in
                self.commandHandler.handleCommandResult(result, command: command)
            }
        case "systems":
            zaparooService.sendJSONCommand(command) { result in
                self.commandHandler.handleCommandResult(result, command: command)
            }
        default:
            // Fallback to generic JSON command for unknown methods
            zaparooService.sendJSONCommand(command) { result in
                self.commandHandler.handleCommandResult(result, command: command)
            }
        }
    }

    private func extractGameNameFromCommand(_ command: String) -> String? {
        // Parse JSON-RPC command to extract game name
        guard let data = command.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = json["params"] as? [String: Any],
              let text = params["text"] as? String else {
            return nil
        }

        // Extract game name from token path (last component)
        // Example: "**launch:NES/listings/games.txt/MegaMan 3" → "MegaMan 3"
        let components = text.split(separator: "/")
        return components.last?.description
    }

    private func sendF12Command() {
        let f12Command = """
        {
          "jsonrpc": "2.0",
          "id": "",
          "method": "launch",
          "params": {
            "text": "**input.keyboard:{f12}"
          }
        }
        """

        AppLogger.standard("🎮 F12 Button pressed - sending MiSTer menu command")

        zaparooService.sendJSONCommand(f12Command) { result in
            switch result {
            case .success(let response):
                AppLogger.standard("✅ F12 command sent successfully: \(response)")
            case .failure(let error):
                AppLogger.standard("❌ F12 command failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleRetry(_ retryContext: RetryContext) {
        AppLogger.standard("🔄 User tapped retry - retrying network request")

        // Remove network error bubble and last user bubble
        if let errorBubbleIndex = chatBubbleService.bubbles.lastIndex(where: { $0.isNetworkError }) {
            let errorBubble = chatBubbleService.bubbles[errorBubbleIndex]
            chatBubbleService.removeBubble(errorBubble)
        }

        // Re-add user message bubble in blue
        chatBubbleService.addUserMessage(retryContext.userMessage)

        // Reset speech service transcription
        speechService.transcription = retryContext.userMessage

        // Retry the AI request with preserved context
        Task {
            await enhancedOpenAIService.processUserMessage(
                userMessage: retryContext.userMessage,
                conversationHistory: Array(retryContext.conversationHistory),
                availableSystems: zaparooService.availableSystems,
                gameContextSnapshot: retryContext.gameContextSnapshot,
                preservedActionType: nil,
                apiKey: settings.openAIAPIKey,
                onCommandGenerated: { command in
                    Task { @MainActor in
                        AppLogger.standard("🎯 Command generated: \(command)")
                        self.sendCommandToMiSTer(command, userMessage: retryContext.userMessage)
                    }
                },
                onCommandExecuted: { result in
                    Task { @MainActor in
                        AppLogger.standard("✅ Command executed: \(result)")
                    }
                }
            )

            // CRITICAL: Reset state back to idle after AI processing completes
            speechService.resetToIdle()
        }
    }
}

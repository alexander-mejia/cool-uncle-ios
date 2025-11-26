//
//  DebugContentView.swift (was ContentView.swift)
//  Cool Uncle
//
//  Created by Alexander Mejia on 7/29/25.
//

import SwiftUI

#if DEBUG
struct DebugContentView: View {
    @StateObject private var speechService = SpeechService()
    @StateObject private var enhancedOpenAIService = EnhancedOpenAIService()
    @StateObject private var ttsService = AVSpeechService()
    @StateObject private var commandHandler = MiSTerCommandHandler()
    @ObservedObject var zaparooService: ZaparooService
    @ObservedObject var settings: AppSettings
    @State private var showingSettings = false
    @State private var showingGameHistory = false
    @State private var showingSessionLogTest = false
    @State private var showingBugReport = false
    @State private var conversationHistory: [ChatMessage] = []
    @State private var showWakeModeAlert = false

    // Sentiment service removed - now handled by Call C in EnhancedOpenAIService

    // DEBUG: Wake word visualization state
    #if DEBUG
    @State private var maxWakeWordScore: Float = 0.0
    @State private var maxScoreDecayTimer: Timer?
    #endif

    var body: some View {
        // Phase 3: Set speech completion handler INLINE in body (guaranteed to run)
        // This ensures both PTT and wake word trigger sendToOpenAI after recording completes
        let _ = speechService.setSpeechCompletionHandler {
            self.sendToOpenAI()
        }
        VStack(spacing: 0) {
            // Main content area
            VStack(spacing: 16) {
                // Connection status at top (compact)
                if !zaparooService.lastError.isEmpty {
                    Text("Error: \(zaparooService.lastError)")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .padding(.top, 8)
                }
                
                if !speechService.isAuthorized {
                    VStack(spacing: 20) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.red)
                    
                    Text("Microphone and Speech Recognition permissions are required")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Request Permissions") {
                        speechService.requestPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 20) {
                    if speechService.requiresSiriEnablement {
                        Text("Enable Siri & Dictation in Settings → Siri & Search → Talk to Siri. Turn on ‘Press Side Button for Siri’ or ‘Hey Siri’ so Apple can install the speech packages.")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Transcription Display
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Voice Input")
                                .font(.headline)
                            
                            if speechService.isRecording {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(speechService.isRecording ? 1.2 : 1.0)
                                        .animation(.easeInOut(duration: 0.5).repeatForever(), value: speechService.isRecording)
                                    Text("Recording")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            } else if speechService.isProcessing {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Processing")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                            
                            Spacer()

                            // Phase 3: Debug toggle for wake word testing
                            #if DEBUG
                            Button(speechService.isWakeWordEnabled ? "Wake: ON" : "Wake: OFF") {
                                speechService.isWakeWordEnabled.toggle()
                            }
                            .font(.caption2)
                            .buttonStyle(.borderedProminent)
                            .tint(speechService.isWakeWordEnabled ? .green : .gray)
                            .controlSize(.mini)
                            #endif

                            // Debug button for recommend_confirm override
                            #if DEBUG
                            Button("recommend_confirm") {
                                testRecommendConfirmOverride()
                            }
                            .font(.caption2)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            #endif
                        }
                        
                        ScrollView {
                            Text(getVoiceInputText())
                                .padding()
                                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                                .background(getVoiceInputBackgroundColor())
                                .cornerRadius(10)
                                .font(.body)
                        }
                        .frame(maxHeight: 180)

                        // DEBUG: Wake word & VAD visualization
                        #if DEBUG
                        HStack(spacing: 0) {
                            GeometryReader { geo in
                                let currentScore = speechService.wakeWordScore
                                let displayScore = max(currentScore, maxWakeWordScore)
                                let scoreNorm = CGFloat(min(1.0, displayScore))
                                let threshold = CGFloat(0.25)  // WakeWordConstants.kwsThreshold
                                let thresholdX = geo.size.width * threshold

                                ZStack(alignment: .leading) {
                                    // Background
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.secondary.opacity(0.1))

                                    // Max score fill (fading out) - shows decay
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.blue.opacity(Double(maxWakeWordScore >= 0.25 ? 0.9 : 0.3)))
                                        .frame(width: geo.size.width * CGFloat(min(1.0, maxWakeWordScore)))
                                        .animation(.easeOut(duration: 0.5), value: maxWakeWordScore)

                                    // Current score fill (real-time) - bright hot indicator
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(.blue.opacity(currentScore >= 0.25 ? 1.0 : 0.0))
                                        .frame(width: geo.size.width * CGFloat(min(1.0, currentScore)))

                                    // Threshold marker (vertical line at 0.25) - 3px wide
                                    Rectangle()
                                        .fill(.red.opacity(0.6))
                                        .frame(width: 3)
                                        .offset(x: thresholdX - 1.5)  // Center the 3px line
                                }
                                .overlay(
                                    // Green stroke when VAD detects speech
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(speechService.vadSpeechPresent ? .green : .clear, lineWidth: 1)
                                )
                                .onChange(of: currentScore) { oldValue, newValue in
                                    // Update max score when current score increases
                                    if newValue > maxWakeWordScore {
                                        maxWakeWordScore = newValue

                                        // Cancel previous decay timer
                                        maxScoreDecayTimer?.invalidate()

                                        // Start 0.5s hold + 0.5s fade timer
                                        maxScoreDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                                            // After 0.5s hold, fade out over 0.5s
                                            withAnimation(.easeOut(duration: 0.5)) {
                                                maxWakeWordScore = 0.0
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                        #endif
                    }

                    // Natural Language AI Response
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("AI Response")
                                .font(.headline)

                            if enhancedOpenAIService.isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }

                            Spacer()

                            // Bug Report button - always visible
                            Button(action: { showingBugReport = true }) {
                                Text("Report Issue")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue.opacity(0.7))
                        }
                        
                        ScrollView {
                            Text(enhancedOpenAIService.coolUncleResponse.isEmpty ? "AI responses will appear here..." : enhancedOpenAIService.coolUncleResponse)
                                .padding()
                                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(10)
                                .font(.body)
                        }
                        .frame(maxHeight: 220)
                    }
                    
                    // JSON Commands Display
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("MiSTer Commands")
                                .font(.headline)
                            
                            Spacer()
                            
                            if enhancedOpenAIService.generatedCommand != nil {
                                Text("1 command")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        ScrollView {
                            if enhancedOpenAIService.generatedCommand == nil {
                                Text("JSON commands for MiSTer will appear here...")
                                    .padding()
                                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(10)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Generated Command")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.green)

                                    Text(enhancedOpenAIService.generatedCommand ?? "")
                                        .padding()
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .background(Color.green.opacity(0.1))
                                        .cornerRadius(8)
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                        
                        if let error = enhancedOpenAIService.lastError {
                            Text("Error: \(error)")
                                .foregroundColor(.red)
                                .font(.caption)
                                .padding(.horizontal)
                        }
                    }
                    
                    // Push-to-Talk Button with side status
                    HStack(spacing: 30) {
                        // Left side status
                        VStack(spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(speechService.isRecording ? Color.red : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(speechService.isRecording ? "Recording..." : "Ready")
                                    .font(.caption)
                                    .foregroundColor(speechService.isRecording ? .red : .primary)
                            }
                            
                            Text("Hold to Talk")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // Center PTT Button
                        Button(action: {
                            // Tap action - handle wake word STOP
                            if speechService.recordingState == .recordingWake {
                                speechService.stopRecording()
                                AppLogger.standard("🛑 User manually stopped wake word recording")
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(getPTTButtonColor())
                                    .frame(width: 120, height: 120)
                                    .scaleEffect(speechService.isRecording ? 1.1 : 1.0)
                                    .animation(.easeInOut(duration: 0.1), value: speechService.isRecording)

                                if speechService.isProcessing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .font(.system(size: 30))
                                } else {
                                    Image(systemName: getPTTButtonIcon())
                                        .font(.system(size: 40))
                                        .foregroundColor(.white)
                                }
                        }
                    }
                    .disabled(speechService.isProcessing || speechService.requiresSiriEnablement)
                        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { } onPressingChanged: { isPressing in
                            // Only respond to gestures when not processing
                            guard !speechService.isProcessing else { return }

                            if isPressing {
                                // Button pressed - start PTT if idle
                                if speechService.recordingState == .idle {
                                    ttsService.stopSpeaking()
                                    speechService.startRecording()
                                }
                            } else {
                                // Button released - stop PTT if in PTT mode
                                if speechService.recordingState == .recordingPTT {
                                    speechService.stopRecording()
                                }
                            }
                        }
                        
                        // Right side connection status
                        VStack(spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(connectionStatusColor)
                                    .frame(width: 8, height: 8)
                                Text("MiSTer")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            if zaparooService.connectionState == .disconnected {
                                Button("Connect") {
                                    zaparooService.connect(to: settings.misterIPAddress)
                                }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                            } else {
                                Text(connectionStatusText.components(separatedBy: " ").first ?? "")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                }
                
                Spacer()
            }
            }
            .padding()
            
            // Bottom Tab Bar
            HStack(spacing: 0) {
                // Settings
                Button(action: {
                    showingSettings = true
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "gear")
                            .font(.title2)
                        Text("Settings")
                            .font(.caption)
                    }
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                
                // Disconnect
                Button(action: {
                    zaparooService.disconnect()
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "wifi.slash")
                            .font(.title2)
                        Text("Disconnect")
                            .font(.caption)
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                
                // Game History
                Button(action: {
                    showingGameHistory = true
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "gamecontroller")
                            .font(.title2)
                        Text("Game History")
                            .font(.caption)
                    }
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                // Session Log Test (DEBUG ONLY)
                #if DEBUG
                Button(action: {
                    showingSessionLogTest = true
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                        Text("Test Logs")
                            .font(.caption)
                    }
                    .foregroundColor(.purple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                #endif

                // F12
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
                    .padding(.vertical, 12)
                }
                .disabled(zaparooService.connectionState != .connected)
            }
            .background(Color.gray.opacity(0.1))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.gray.opacity(0.3)),
                alignment: .top
            )
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: settings)
        }
        .sheet(isPresented: $showingGameHistory) {
            GamePreferenceView()
        }
        .sheet(isPresented: $showingSessionLogTest) {
            SessionLogTestView()
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
        .alert("Enable Siri & Dictation", isPresented: Binding(
            get: { speechService.requiresSiriEnablement },
            set: { if !$0 { speechService.requiresSiriEnablement = false } }
        )) {
            Button("Got it", role: .cancel) {
                speechService.requiresSiriEnablement = false
            }
        } message: {
            Text("Cool Uncle needs Siri enabled to use speech recognition. Open Settings → Siri & Search → Talk to Siri, then enable 'Press Side Button for Siri' or 'Hey Siri' before trying again.")
        }
        .alert("Screen Will Stay On", isPresented: $showWakeModeAlert) {
            Button("Got it", role: .cancel) {
                settings.hasSeenWakeModeSleepAlert = true
            }
        } message: {
            Text("When this switch is on, the device won't go to sleep automatically. You'll need to sleep the phone yourself or switch out of the app.")
        }
        .onChange(of: speechService.isWakeWordEnabled) { _, newValue in
            // Show alert on first enable if user hasn't seen it before
            if newValue && !settings.hasSeenWakeModeSleepAlert {
                showWakeModeAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GameActuallyLaunched"))) { notification in
            // Always cancel any pending launch timeout as soon as we receive the signal
            // Some notifications may be missing a parsed gameName; the timeout must still be cleared
            self.commandHandler.launchTimeoutTimer?.invalidate()
            self.commandHandler.pendingLaunchInfo = nil

            let notifiedGameName = notification.userInfo?["gameName"] as? String
            if let gameName = notifiedGameName {
                AppLogger.gameHistory("🎮 Received actual game launch: \(gameName)")

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

                // Sentiment context now handled by Call C in EnhancedOpenAIService
                // Context is captured when game launches are processed

                // Update enhanced OpenAI service with actual game name for ALL launches
                self.enhancedOpenAIService.updateCommandExecutionResult("Command executed successfully", actualGameName: gameName)

                // Complete any pending deferred response for ALL game launches
                Task {
                    await self.enhancedOpenAIService.completeDeferredResponse(actualGameName: gameName)
                }

                // Check if this was a random launch needing Cool Uncle response (legacy handling)
                AppLogger.emit(type: .standard, content: "🐛 RANDOM DEBUG: awaitingRandomGameLaunch=\(self.commandHandler.awaitingRandomGameLaunch) lastProcessedRandomGame='\(self.commandHandler.lastProcessedRandomGame ?? "nil")' gameName='\(gameName)'")
                // FIXED: Only handle as random if it's truly a random action type, not a recommendation
                if self.commandHandler.awaitingRandomGameLaunch &&
                   self.commandHandler.lastProcessedRandomGame != gameName &&
                   self.enhancedOpenAIService.threeCallContext?.actionType == "random" {
                    AppLogger.gameHistory("🎲 Processing random game launch: \(gameName)")

                    // Use the enhanced 3-call system for random game responses
                    Task { @MainActor in
                        AppLogger.emit(type: .debug, content: "CALLING handleRandomGameLaunch with:")
                        AppLogger.emit(type: .debug, content: "   Game Name: \(gameName)")
                        AppLogger.emit(type: .debug, content: "   User Message: \(self.commandHandler.pendingRandomGameRequest ?? "Play a random game")")
                        AppLogger.emit(type: .debug, content: "   Pending Request: \(self.commandHandler.pendingRandomGameRequest ?? "nil")")

                        await self.enhancedOpenAIService.handleRandomGameLaunch(
                            gameName: gameName,
                            userMessage: self.commandHandler.pendingRandomGameRequest ?? "Play a random game",
                            conversationHistory: self.conversationHistory,
                            apiKey: self.settings.openAIAPIKey
                        )
                    }

                    self.commandHandler.awaitingRandomGameLaunch = false
                    self.commandHandler.lastProcessedRandomGame = gameName
                    // Don't clear pendingRandomGameRequest here - it will be cleared after handleRandomGameLaunch completes
                }
            } else {
                // We still proceed with clearing timers above; optionally log for diagnostics
                AppLogger.emit(type: .debug, content: "📣 GameActuallyLaunched received without gameName — timeout cleared")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LaunchGameFromPreferences"))) { notification in
            if let launchCommand = notification.userInfo?["launchCommand"] as? String,
               let gameName = notification.userInfo?["gameName"] as? String {
                AppLogger.gameHistory("🎮 Launching game from preferences: \(gameName)")
                self.sendCommandToMiSTer(launchCommand)
            }
        }
        // Note: Command auto-execution now handled by commandExecutionCallback in 3-call architecture
        // Old onChange(of: openAIService.jsonCommands) removed to prevent duplicate commands
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
        .onAppear {
            // Wire up delegation between CallCDispatchService and SentimentAnalysisService
            CallCDispatchService.shared.setDelegate(SentimentAnalysisService.shared, apiKey: settings.openAIAPIKey)
            AppLogger.standard("🔗 CallCDispatchService delegation wired up to SentimentAnalysisService")

            // Setup unified MiSTer command handler
            commandHandler.setup(
                enhancedOpenAI: enhancedOpenAIService,
                tts: ttsService,
                zaparoo: zaparooService,
                speech: speechService,
                settings: settings,
                uiState: nil  // Debug UI doesn't use transient status
            )
            commandHandler.onAddConversationMessage = { message in
                self.conversationHistory.append(message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MediaIndexingCompleted"))) { _ in
            // System message when media indexing completes
            AppLogger.standard("📚 Media indexing completed - adding system message")

            let indexingMessage = "Indexing complete."

            // Set response (triggers .onChange handler for TTS)
            enhancedOpenAIService.coolUncleResponse = indexingMessage

            // Add to conversation history
            let chatMessage = ChatMessage(role: "assistant", content: indexingMessage)
            conversationHistory.append(chatMessage)
        }
    }

    // MARK: - Computed Properties
    private var connectionStatusColor: Color {
        switch zaparooService.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var connectionStatusText: String {
        switch zaparooService.connectionState {
        case .connected:
            return "Connected to MiSTer (\(settings.misterIPAddress))"
        case .connecting:
            return "Connecting to MiSTer..."
        case .disconnected:
            return "Disconnected from MiSTer"
        case .error(let error):
            return "Connection Error: \(error)"
        }
    }
    
    // MARK: - Helper Methods for Voice Input UI
    private func getVoiceInputText() -> String {
        // Use the shared displayTranscription computed property for consistent behavior
        let baseText = speechService.displayTranscription

        // Add prompt text when idle
        if !speechService.isRecording && !speechService.isProcessing {
            return baseText.isEmpty ? "Press and hold the button to speak..." : baseText
        }

        return baseText
    }
    
    private func getVoiceInputBackgroundColor() -> Color {
        if speechService.isRecording {
            return Color.red.opacity(0.1)
        } else if speechService.isProcessing {
            return Color.blue.opacity(0.1)
        } else {
            return Color.gray.opacity(0.1)
        }
    }
    
    private func getPTTButtonColor() -> Color {
        if speechService.isProcessing {
            return Color.gray.opacity(0.7)
        }

        switch speechService.recordingState {
        case .idle:
            return .blue       // Ready to record
        case .recordingPTT:
            return .green      // Recording via button press
        case .recordingWake:
            return .red        // Recording via wake word (stoppable)
        case .processingRequest:
            return .red        // AI processing - user can tap STOP to cancel
        }
    }

    private func getPTTButtonIcon() -> String {
        // Red STOP icon during wake word recording, mic otherwise
        speechService.recordingState == .recordingWake ? "stop.fill" : "mic.fill"
    }

    // MARK: - Methods
    
    /// Debug function to override next command to recommend_confirm
    private func testRecommendConfirmOverride() {
        #if DEBUG
        print("🔧 DEBUG: Adding 5 minutes to game session timer")
        #endif
        AppLogger.standard("🔧 DEBUG: Adding 5 minutes to session timer to trigger recommend_confirm")

        // Subtract 5 minutes from sessionStartTime to simulate 5 additional minutes of gameplay
        if let currentStartTime = CurrentGameService.shared.sessionStartTime {
            CurrentGameService.shared.sessionStartTime = currentStartTime.addingTimeInterval(-5 * 60) // 5 minutes ago
            #if DEBUG
            print("🔧 DEBUG: Session timer adjusted by 5 minutes")
            #endif
        } else {
            // If no session is active, create one that started 5 minutes ago
            CurrentGameService.shared.sessionStartTime = Date().addingTimeInterval(-5 * 60)
            #if DEBUG
            print("🔧 DEBUG: Created new session timer set to 5 minutes ago")
            #endif
        }
        
        // Add haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
    }
    
    private func sendCommandToMiSTer(_ command: String, userMessage: String? = nil) {
        // Parse the command to determine the appropriate method to call
        guard let commandData = command.data(using: .utf8),
              let commandDict = try? JSONSerialization.jsonObject(with: commandData) as? [String: Any],
              let method = commandDict["method"] as? String else {
            AppLogger.emit(type: .error, content: "Failed to parse command: \(command)")
            return
        }
        
        var shouldExecute = true
        
        // Check if this is a recommend_confirm launch that should be cached
        if let actionType = enhancedOpenAIService.threeCallContext?.actionType,
           actionType == "recommend_confirm",
           method == "launch" {
            
            // Extract launch text to check if this is an input command
            let params = commandDict["params"] as? [String: Any]
            let launchText = params?["text"] as? String ?? ""
            
            // Don't cache input commands for recommendation confirmation
            if launchText.hasPrefix("**input.") {
                AppLogger.misterRequest("ℹ️ INPUT COMMAND: Skipping recommendation cache for utility command: \(launchText)")
                shouldExecute = true // Execute normally, don't cache
            } else {
            
            // FIX: Clear any existing cache before setting new one
            if enhancedOpenAIService.isPendingRecommendationValid() {
                AppLogger.misterRequest("🔄 CACHE FIX: Clearing old cache before setting new recommendation")
                enhancedOpenAIService.clearPendingRecommendation()
            }
            
            // Extract game name and cache
            let gameName = extractGameNameFromLaunch(commandDict)
            enhancedOpenAIService.setPendingRecommendation(
                command: command,
                gameName: gameName
            )
            AppLogger.misterRequest("📌 Intercepted recommend_confirm - cached for confirmation")
            shouldExecute = false
            
            // Signal completion so flow continues to Call B
            enhancedOpenAIService.commandExecutionResult = "Recommendation cached - awaiting confirmation"
            }
        }
        
        // Only execute if not cached
        guard shouldExecute else { return }
        
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

    // handleCommandResult removed - now using unified MiSTerCommandHandler service

    private func handleSearchResults(_ results: [[String: Any]]) {
        // Do NOT increment search counter when results are found - this is a SUCCESS
        // Only zero results (handled in EnhancedOpenAIService.handleZeroResults()) should increment

        AppLogger.standard("⚠️ WARNING: Legacy handleSearchResults() was called!")
        AppLogger.standard("   This should not happen with batch tracking enabled")
        AppLogger.standard("   Please report this as a bug if seen in production")

        AppLogger.standard("🔍 Processing \(results.count) search results for AI (no counter increment - this is success)")
        
        // Log current context state for debugging
        if let context = enhancedOpenAIService.threeCallContext {
            AppLogger.standard("🔄 PROGRAM: Context state (no changes):")
            AppLogger.standard("   🎯 originalSearchQuery: \(context.originalSearchQuery ?? "nil")")
            AppLogger.standard("   ⚡ actionType: \(context.actionType ?? "nil")")
        }
        
        // Convert search results to a readable format for the AI
        var resultText = "Search results found:\n"
        for (index, result) in results.enumerated() {
            if let name = result["name"] as? String,
               let path = result["path"] as? String {
                resultText += "\(index + 1). \"\(name)\" at path: \(path)\n"
            }
        }
        
        // Capture the original user request before it changes
        let originalUserRequest = speechService.transcription
        
        // Create search result message
        let _ = enhancedOpenAIService.threeCallContext?.actionType
        
        // Regular search: AI should try to match original request
        let searchResultMessage = "[SYSTEM_INTERNAL_SEARCH_RESULTS] User has requested: \"\(originalUserRequest)\"\n\nYou should choose the game that BEST MATCHES the user's request and launch the USA version.\n\n\(resultText)\n\n⚠️ CRITICAL PATH USAGE RULE:\nEach numbered line contains a complete, ready-to-use path. Pick a line number and use the ENTIRE path string after \"at path:\" exactly as written.\n⚠️ CRITICAL: Do NOT modify, truncate, or \"clean up\" the path.\n⚠️ FAILURE EXAMPLE: AI truncated \"Arcade/_alternatives/_Marvel Super Heroes Vs. Street Fighter/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra\"\n⚠️ to \"Arcade/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra\" → LAUNCH FAILED\n✅ CORRECT: Use the complete path including all /_alternatives/ subdirectories exactly as written.\n\nChoose the game that most closely matches what the user actually asked for."
        
        // Add the search result message to conversation history  
        let systemMessage = ChatMessage(role: "user", content: searchResultMessage)
        conversationHistory.append(systemMessage)
        
        AppLogger.verbose("Sending internal search results to AI (should generate single game description + launch)")
        
        Task {
            // Preserve the current game context through search result processing
            // This ensures sentiment analysis targets the right game
            let searchResultSnapshot = CurrentGameService.shared.createGameContextSnapshot(
                forUserMessage: searchResultMessage
            )
            
            // CRITICAL: Preserve the action type from the original request
            // Get the action type from the current context to maintain Phase 2 behavior
            let preservedActionType = enhancedOpenAIService.threeCallContext?.actionType
            
            
            AppLogger.emit(type: .debug, content: "Search result processing: Using actionType = \(preservedActionType ?? "nil")")
            
            await enhancedOpenAIService.processUserMessage(
                userMessage: searchResultMessage,
                conversationHistory: Array(conversationHistory),
                availableSystems: zaparooService.availableSystems,
                gameContextSnapshot: searchResultSnapshot,
                preservedActionType: preservedActionType,
                apiKey: settings.openAIAPIKey,
                onCommandGenerated: { command in
                    Task { @MainActor in
                        AppLogger.standard("🔍 Search result generated command: \(command)")
                        // Use the original user request from before the search
                        self.sendCommandToMiSTer(command, userMessage: originalUserRequest)
                    }
                },
                onCommandExecuted: { result in
                    Task { @MainActor in
                        AppLogger.standard("🔍 Search result command executed: \(result)")
                    }
                }
            )
            
            // Add AI response to conversation history after response is received
            if !enhancedOpenAIService.coolUncleResponse.isEmpty {
                let assistantMessage = ChatMessage(role: "assistant", content: enhancedOpenAIService.coolUncleResponse)
                conversationHistory.append(assistantMessage)
                
                // Keep conversation history manageable (last 20 messages = 10 exchanges)
                if conversationHistory.count > 20 {
                    conversationHistory.removeFirst(conversationHistory.count - 20)
                }
            }
        }
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

        #if DEBUG
        print("🎮 F12 Button pressed - sending MiSTer menu command")
        print("📝 Original F12 JSON: \(f12Command)")
        #endif

        zaparooService.sendJSONCommand(f12Command) { result in
            switch result {
            case .success(let response):
                #if DEBUG
                print("✅ F12 command sent successfully")
                print("📨 MiSTer response: \(response)")
                #endif
            case .failure(let error):
                #if DEBUG
                print("❌ F12 command failed: \(error.localizedDescription)")
                #endif
            }
        }
    }
    
    private func sendToOpenAI() {
        guard !speechService.transcription.isEmpty else { return }
        
        // Log the user's voice input
        AppLogger.userInput("\"\(speechService.transcription)\"")
        
        // CRITICAL: Create immutable game context snapshot BEFORE AI processes anything
        // This prevents race conditions with sentiment analysis
        let gameContextSnapshot: GameContextSnapshot = {
            // Check if we should restore stopped game context
            if CurrentGameService.shared.currentGameName == nil,
               let stopSnapshot = enhancedOpenAIService.getLastStopGameSnapshot(),
               enhancedOpenAIService.isStopGameContextValid() {
                AppLogger.gameHistory("🔄 Restoring stopped game context: \(stopSnapshot.sentimentTargetGame)")
                return stopSnapshot
            } else {
                // Normal case: create fresh snapshot
                return CurrentGameService.shared.createGameContextSnapshot(
                    forUserMessage: speechService.transcription
                )
            }
        }()
        AppLogger.gameHistory("🎯 Captured context BEFORE AI: Current game = \(gameContextSnapshot.currentGame ?? "None")")

        // NOTE: Call C is now queued AFTER Call A determines actionType (moved to EnhancedOpenAIService)
        // This prevents rate limiting and ensures Call C has correct actionType context

        // Create user message but DON'T add it yet - let the AI service handle the full conversation
        // This ensures the conversation history includes ALL previous exchanges
        let userMessage = ChatMessage(role: "user", content: speechService.transcription)


        // Capture the user message once to prevent it from changing during async operations
        let capturedUserMessage = speechService.transcription
        
        Task {
            // Pass the conversation history WITHOUT the current message
            // The AI service will handle adding messages in the right order
            await enhancedOpenAIService.processUserMessage(
                userMessage: capturedUserMessage,
                conversationHistory: Array(conversationHistory), // Pass history WITHOUT current message
                availableSystems: zaparooService.availableSystems,
                gameContextSnapshot: gameContextSnapshot,
                preservedActionType: nil, // New user message - no preserved action type
                apiKey: settings.openAIAPIKey,
                onCommandGenerated: { command in
                    Task { @MainActor in
                        AppLogger.standard("🎯 Command generated by 3-call system: \(command)")
                        self.sendCommandToMiSTer(command, userMessage: capturedUserMessage)
                    }
                },
                onCommandExecuted: { result in
                    Task { @MainActor in
                        AppLogger.standard("✅ Command execution result: \(result)")
                    }
                }
            )
            
            // Debug: Check OpenAI response state
            AppLogger.verbose("🔍 Enhanced OpenAI Response Debug:")
            AppLogger.verbose("   📝 Cool Uncle response length: \(enhancedOpenAIService.coolUncleResponse.count)")
            AppLogger.verbose("   📝 Cool Uncle response: '\(enhancedOpenAIService.coolUncleResponse.prefix(100))...'")
            AppLogger.verbose("   🔍 Response empty check: \(enhancedOpenAIService.coolUncleResponse.isEmpty)")
            
            // Add BOTH user message and AI response to conversation history in order
            conversationHistory.append(userMessage)
            
            // Add AI response to conversation history if there is one
            if !enhancedOpenAIService.coolUncleResponse.isEmpty {
                AppLogger.gameHistory("✅ Enhanced OpenAI response not empty - adding to conversation")
                
                let assistantMessage = ChatMessage(role: "assistant", content: enhancedOpenAIService.coolUncleResponse)
                conversationHistory.append(assistantMessage)
                
                // NOTE: Game recommendation extraction and sentiment analysis now handled by 3-call architecture (Call C)
                extractAndSetRecommendedGame(from: enhancedOpenAIService.coolUncleResponse)
            } else {
                AppLogger.gameHistory("⚠️ Enhanced OpenAI response is empty (command-only response)")
            }
            
            // Keep conversation history manageable (last 20 messages = 10 exchanges)
            if conversationHistory.count > 20 {
                conversationHistory.removeFirst(conversationHistory.count - 20)
            }
        }
    }
    
    // MARK: - Sentiment Analysis Helpers
    
    /// Extract game name from AI response for sentiment context tracking
    private func extractAndSetRecommendedGame(from response: String) {
        // Simple game name extraction - could be enhanced with more sophisticated parsing
        let commonGames = [
            "pga golf", "golf", "contra", "super metroid", "metroid", "mario", "zelda", "sonic",
            "pac-man", "tetris", "street fighter", "mega man", "castlevania", "final fantasy",
            "chrono trigger", "secret of mana", "donkey kong", "mortal kombat", "king of fighters",
            "metal slug", "gradius", "r-type", "bubble bobble", "galaga", "centipede", "asteroids"
        ]
        
        let lowercaseResponse = response.lowercased()
        for game in commonGames {
            if lowercaseResponse.contains(game) {
                let gameName = game.capitalized
                // Sentiment context now handled by Call C in EnhancedOpenAIService
                AppLogger.gameHistory("Extracted recommended game: \(gameName)")
                return
            }
        }
    }
    
    // trackGameLaunch removed - now using unified MiSTerCommandHandler service

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
    
    private func getTextFromLaunchCommand(_ command: String) -> String? {
        // Extract the text parameter from launch command JSON
        if let data = command.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let params = json["params"] as? [String: Any],
           let text = params["text"] as? String {
            return text
        }
        return nil
    }
    
    private func extractGameNameFromLaunchPath(_ launchPath: String) -> String? {
        
        // Extract game name from various launch path formats
        // Example: "SNES/Games/Super Mario World.sfc" -> "Super Mario World"
        // Example: "**launch:Amiga/listings/games.txt/Contra[en]" -> "Contra"
        
        if launchPath.contains("**launch:") {
            // Amiga format: **launch:Amiga/listings/games.txt/GameName[region]
            let components = launchPath.components(separatedBy: "/")
            if let lastComponent = components.last {
                let gameName = lastComponent.components(separatedBy: "[").first ?? lastComponent
                return gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            // Standard format: System/Path/GameName.ext
            let components = launchPath.components(separatedBy: "/")
            if let lastComponent = components.last {
                // Remove known game file extensions (preserve game names with periods)
                let gameExtensions = [".zip", ".sfc", ".smc", ".md", ".gen", ".nes", ".gb", ".gbc", ".gba",
                                     ".pce", ".ngp", ".ws", ".col", ".sg", ".msx", ".vb", ".gg", ".sms",
                                     ".bin", ".cue", ".chd", ".pbp", ".cdi", ".gdi", ".iso"]
                
                var gameNameWithoutExt = lastComponent
                for fileExtension in gameExtensions {
                    if lastComponent.lowercased().hasSuffix(fileExtension) {
                        gameNameWithoutExt = String(lastComponent.dropLast(fileExtension.count))
                        break
                    }
                }
                
                // Remove common suffixes like (USA), (Europe), etc.
                let cleanName = gameNameWithoutExt.replacingOccurrences(of: #"\s*\([^)]*\).*"#, with: "", options: .regularExpression)
                return cleanName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    // MARK: - Random Game Launch Handler
    
    private func handleRandomGameLaunch(gameName: String) {
        // Extract system from conversation history to provide context
        let recentMessages = conversationHistory.suffix(3)
        _ = recentMessages.last(where: { $0.role == "user" })?.content ?? ""
        
        // Create context-aware message for AI
        let contextMessage = "[SYSTEM_INTERNAL_RANDOM_GAME] Launched: \(gameName)"
        
        AppLogger.gameHistory("🎲 Sending random game context to AI: \(contextMessage)")
        
        // Add to conversation history and send to AI
        let systemMessage = ChatMessage(role: "user", content: contextMessage)
        conversationHistory.append(systemMessage)
        
        // Send to Enhanced OpenAI for Cool Uncle response
        Task { @MainActor in
            // Create snapshot for random game context processing
            // Use CurrentGameService to get complete context including launch command
            let randomGameSnapshot: GameContextSnapshot
            if CurrentGameService.shared.currentGameName?.lowercased() == gameName.lowercased() {
                randomGameSnapshot = CurrentGameService.shared.createGameContextSnapshot(forUserMessage: contextMessage)
            } else {
                // Fallback for timing edge cases
                randomGameSnapshot = GameContextSnapshot(
                    currentGame: gameName,
                    currentSystem: zaparooService.lastLaunchedGameSystem,
                    forUserMessage: contextMessage,
                    lastLaunchCommand: nil
                )
            }
            
            await enhancedOpenAIService.processUserMessage(
                userMessage: contextMessage,
                conversationHistory: Array(conversationHistory.dropLast()), // Exclude the message we just added
                availableSystems: zaparooService.availableSystems,
                gameContextSnapshot: randomGameSnapshot,
                preservedActionType: "random", // CRITICAL FIX: Preserve random actionType to avoid duplicate Call B processing
                apiKey: settings.openAIAPIKey,
                onCommandGenerated: { command in
                    Task { @MainActor in
                        AppLogger.standard("🎲 Random game response command: \(command)")
                        // Random game responses typically don't need additional commands
                    }
                },
                onCommandExecuted: { result in
                    Task { @MainActor in
                        AppLogger.standard("🎲 Random game response completed: \(result)")
                    }
                }
            )
        }
    }
    
    // MARK: - Current Game State Management
    
    /// Update current game state with launch command for future re-launch
}

#Preview {
    let settings = AppSettings()
    DebugContentView(
        zaparooService: ZaparooService(settings: settings),
        settings: settings
    )
}
#endif

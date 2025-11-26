import Foundation
import Speech
import AVFoundation
#if os(iOS)
import UIKit
#endif

@MainActor
class SpeechService: ObservableObject {
    @Published var transcription: String = ""
    @Published var isRecording: Bool = false
    @Published var isProcessing: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isHotMicActive: Bool = false
    @Published var requiresSiriEnablement: Bool = false

    private var audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finalizationTimer: Timer?
    private var speechCompletionHandler: (() -> Void)?

    // iOS 26 SpeechAnalyzer components (minimum deployment iOS 26.0)
    // NOTE: These are created FRESH for each recording session (not reused)
    // because SpeechAnalyzer cannot be reused after finalization
    private var currentAnalyzer: SpeechAnalyzer?
    private var currentTranscriber: SpeechTranscriber?
    private var speechDetector: SpeechDetector?
    private var detectorTask: Task<Void, Never>?
    private var transcriberTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    // Audio input stream for SpeechAnalyzer
    // IMPORTANT: Both the stream AND continuation must be stored to prevent deallocation
    private var audioInputStreamSequence: AsyncStream<AnalyzerInput>?
    private var audioInputStream: AsyncStream<AnalyzerInput>.Continuation?

    // Track TTS speaking state to prevent wake word feedback loop
    private var isTTSSpeaking: Bool = false

    // Atomic flag to prevent duplicate wake word processing
    private var isProcessingWakeWord = false

    // Accumulate finalized segments to prevent text loss on long pauses
    private var accumulatedText: String = ""
    private var lastSegment: String = ""  // Track the current segment being built

    // Hot mic state
    private var hasInstalledTap: Bool = false

    // Cloud fallback tracking
    private var hasAttemptedFallback: Bool = false

    // Custom language model
    private var gamingModelURL: URL?

    // Resampler for non-16kHz hardware (Phase 1: Audio pipeline migration)
    private var resampler: Resampler?
    private var needsResampling: Bool = false

    // Unified 5-second ring buffer for pre-roll (Phase 2: Ring buffer upgrade)
    // Supports 0.35s pre-roll for PTT and 1.0s pre-roll for wake word detection
    private var audioRingBuffer: WakeAudioBuffer?

    // Phase 3: Wake Word System
    // Wake word toggle
    @Published var isWakeWordEnabled: Bool = false {
        didSet {
            if isWakeWordEnabled { initializeWakeWord() }
            else { teardownWakeWord() }
        }
    }

    // Wake word engine components (nil when disabled)
    private var wakeWordEngine: OpenWakeWordEngine?
    private var sileroVAD: SileroVAD?

    // Screen management for wake word mode
    private var originalBrightness: CGFloat = 1.0  // Save user's brightness setting
    private var dimTimer: Timer?  // Timer to dim screen after inactivity
    private var isDimmed: Bool = false  // Track current dim state

    // Recording state machine
    enum RecordingState {
        case idle              // Not recording, wake word listening (if enabled)
        case recordingPTT      // Button held, wake word blocked
        case recordingWake     // Wake word triggered, button becomes STOP
        case processingRequest // AI processing user request, button shows RED STOP for cancellation
    }
    @Published var recordingState: RecordingState = .idle

    // Debug visualization (DEBUG builds only)
    #if DEBUG
    @Published var wakeWordScore: Float = 0.0
    @Published var vadSpeechPresent: Bool = false
    #endif

    // VAD endpointing state
    private var vadEndpointingActive: Bool = false
    private var lastSpeechTime: TimeInterval = 0
    private var wakeWordDetectedTime: TimeInterval = 0  // When wake word was detected
    private var actualPreRollDuration: Double = 0.0     // Actual pre-roll duration for timestamp filtering
    private var actualPreRollSampleCount: Int = 0       // Actual pre-roll samples extracted
    private var wakeWordSampleIndex: Int = 0            // OpenWakeWord's sample position at detection
    private var ringBufferSampleCountAtWake: Int = 0    // Ring buffer's total samples at wake detection

    // ASR-based failsafe endpointing
    private var lastTranscriptionUpdateTime: TimeInterval = 0  // When ASR last produced new text
    private var lastTranscriptionText: String = ""  // Last transcription to detect changes

    // Pre-warm tracking for SpeechAnalyzer (fixes first wake word failure)
    private var isAnalyzerPreWarmed: Bool = false

    // Debounce/refractory tracking
    private var lastButtonPressTime: TimeInterval = 0
    private var lastWakeTime: TimeInterval = 0

    // MARK: - Consumer UI Integration

    /// Reference to UI state service for timer updates
    /// Optional because debug UI doesn't use this service
    private weak var uiStateService: UIStateService?

    /// Inject UI state service (called by ConsumerView on appear)
    func setUIStateService(_ service: UIStateService) {
        self.uiStateService = service
    }

    /// Computed property for real-time transcription display in UI
    /// Returns appropriate text based on recording/processing state
    /// Used by both DebugContentView and ConsumerView for consistent behavior
    var displayTranscription: String {
        if isRecording {
            return transcription.isEmpty ? "Listening..." : transcription
        } else if isProcessing {
            return transcription.isEmpty ? "Processing..." : transcription
        } else {
            return transcription
        }
    }

    init() {
        configureLocaleObservation()
        updateSpeechRecognizerLocale()
        requestPermissions()
        prepareAudioEngine()
        loadGamingModel()
        setupLifecycleObservers()

        // Initialize iOS 26 SpeechAnalyzer (detector + transcriber)
        Task {
            await setupSpeechAnalyzer()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupLifecycleObservers() {
        // App lifecycle notifications for battery optimization
        NotificationCenter.default.addObserver(
            forName: Notification.Name("AppEnteringBackground"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fullTeardown()
                AppLogger.standard("🔇 SpeechService: Full teardown for background mode")
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("AppBecomingInactive"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Stop any active recording when becoming inactive (screen lock, task switcher)
                if self?.isRecording == true {
                    self?.stopRecording()
                }
                // Mute hot mic input but keep engine running for quick resume
                self?.audioEngine.inputNode.isVoiceProcessingInputMuted = true
                AppLogger.verbose("🔇 SpeechService: Muted hot mic for inactive state")
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("AppBecomingActive"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Restart hot mic if it was stopped (e.g., coming back from background)
                if !self.isHotMicActive && self.isAuthorized {
                    self.prepareAudioEngine()
                    AppLogger.standard("🎙️ SpeechService: Hot mic restarted after returning to active")
                } else if self.isHotMicActive {
                    // Unmute if we were just inactive
                    self.audioEngine.inputNode.isVoiceProcessingInputMuted = false
                    AppLogger.verbose("🎙️ SpeechService: Unmuted hot mic")
                }
            }
        }
    }

    /// Load custom gaming pronunciation model URL (iOS 17+)
    private func loadGamingModel() {
        guard #available(iOS 17.0, *) else { return }
        if let modelURL = Bundle.main.url(forResource: "gaming_pronunciation_model", withExtension: "bin") {
            gamingModelURL = modelURL
            AppLogger.standard("🎮 Gaming pronunciation model found in bundle")
        } else {
            AppLogger.connection("⚠️ Gaming pronunciation model not found in bundle")
        }
    }

    /// Pre-configure audio session to reduce startup delay
    private func prepareAudioEngine() {
        guard isAuthorized else { return }

        // CRITICAL: Never configure audio while backgrounded - iOS forbids audio session activation
        #if os(iOS)
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            AppLogger.verbose("🔇 Skipping audio engine preparation - app not active (state: \(appState.rawValue))")
            return
        }
        #endif

        // Configure duplex audio so TTS can play while mic is warmed
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Audio session mode: Choose between .default (raw) or .videoRecording (mode-level processing)
            // A/B testing flag: WakeWordConstants.useVideoRecordingMode (default: false)
            let audioMode: AVAudioSession.Mode = WakeWordConstants.useVideoRecordingMode ? .videoRecording : .default

            try audioSession.setCategory(
                .playAndRecord,
                mode: audioMode,  // .default = raw audio + engine voice processing
                                  // .videoRecording = mode-level AGC + noise suppression
                                  // For A/B testing: Toggle WakeWordConstants.useVideoRecordingMode
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            )

            AppLogger.standard("🎧 Audio session mode: \(audioMode == .default ? ".default" : ".videoRecording")")
            // Set preferred sample rate to 16kHz for unified audio pipeline
            // Rationale: OpenWakeWord models require 16kHz, Silero VAD expects 16kHz,
            // and Apple STT internally resamples to 16kHz anyway (no accuracy loss).
            // This unified sample rate simplifies the pipeline and enables future wake word features.
            try audioSession.setPreferredSampleRate(16000.0)
            try audioSession.setPreferredIOBufferDuration(0.005) // 5ms for lower latency

            // Verify if we got native 16kHz or need resampling
            let actualRate = audioSession.sampleRate
            if abs(actualRate - 16000.0) > 0.1 {
                AppLogger.connection("⚠️ Got \(actualRate)Hz, will resample to 16kHz")
                needsResampling = true
            } else {
                AppLogger.standard("✅ Native 16kHz achieved, no resampling needed")
                needsResampling = false
            }

            AppLogger.standard("✅ Audio session pre-configured for duplex (playAndRecord)")
            // Prefer the bottom (front-facing) built-in mic for clearer voice capture if available
            selectBestMicDataSource()
        } catch {
            AppLogger.connection("Failed to pre-configure audio session: \(error)")
        }

        // Start hot mic after permissions to keep input primed and build pre-roll
        startHotMic()
        
        // Observe TTS notifications to suspend/unmute mic during playback
        NotificationCenter.default.addObserver(forName: Notification.Name("TTSDidStart"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isTTSSpeaking = true
            self.isRecording = false
            self.audioEngine.inputNode.isVoiceProcessingInputMuted = true
            AppLogger.verbose("🔇 TTS started - wake word detection suspended, mic muted")
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("TTSDidFinish"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isTTSSpeaking = false
            self.audioEngine.inputNode.isVoiceProcessingInputMuted = false

            #if DEBUG
            let audioSession = AVAudioSession.sharedInstance()
            AppLogger.verbose("🔧 [DEBUG] TTSDidFinish - Unmuted mic, audio session category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
            #endif
        }
    }

    // Choose the best built-in mic data source (bottom/front) for voice capture when available
    private func selectBestMicDataSource() {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else { return }
        // Find built-in mic port
        if let builtIn = inputs.first(where: { $0.portType == .builtInMic }) {
            // Prefer a data source with bottom/front orientation
            if let ds = builtIn.dataSources?.first(where: { $0.orientation == .front || $0.orientation == .bottom }) ?? builtIn.dataSources?.first {
                do {
                    try builtIn.setPreferredDataSource(ds)
                    try session.setPreferredInput(builtIn)
                    AppLogger.verbose("🎙️ Selected mic data source: \(ds.dataSourceName)")
                } catch {
                    AppLogger.connection("Failed to set preferred mic data source: \(error)")
                }
            }
        }
    }


    // MARK: - Hot Mic / Pre-roll
    private func startHotMic() {
        // CRITICAL: Never start hot mic while app is backgrounded - iOS forbids audio session activation
        #if os(iOS)
        let appState = UIApplication.shared.applicationState
        guard appState == .active else {
            AppLogger.verbose("🔇 Skipping hot mic start - app not active (state: \(appState.rawValue))")
            return
        }
        #endif

        if hasInstalledTap {
            if !audioEngine.isRunning {
                do { try audioEngine.start(); isHotMicActive = true } catch { AppLogger.connection("Hot mic restart failed: \(error)") }
            }
            return
        }
        do { try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation) } catch {
            AppLogger.connection("Failed to activate audio session for hot mic: \(error)")
        }
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Enable iOS voice processing for AGC, noise suppression, and echo cancellation
        // This processes audio BEFORE the tap, so all downstream consumers (wake word, STT, ring buffer)
        // receive the same enhanced audio stream.
        //
        // A/B Testing: Two options for voice processing:
        //   Option A (Default): Engine-level via setVoiceProcessingEnabled(true)
        //     - Controlled by: WakeWordConstants.useVoiceProcessing (default: true)
        //     - Benefits: AGC + noise suppression + echo cancellation
        //   Option C: Mode-level via .videoRecording audio session mode
        //     - Controlled by: WakeWordConstants.useVideoRecordingMode (default: false)
        //     - Benefits: Similar AGC + noise suppression at session level
        //
        // To A/B test: Toggle either flag in Constants.swift or via WakeWordRuntimeConfig
        // Test with 10 "Hey mister [hard command]" phrases and compare accuracy
        //
        // CRITICAL: Must be called BEFORE installTap() and while engine is stopped.
        // Requires .playAndRecord category (which we already use for TTS).
        if WakeWordConstants.useVoiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)

                // Verify it actually enabled
                if inputNode.isVoiceProcessingEnabled {
                    AppLogger.standard("✅ Voice processing enabled (AGC + noise suppression + echo cancellation)")
                } else {
                    AppLogger.connection("⚠️ Voice processing failed to enable - check audio session configuration")
                }
            } catch {
                AppLogger.connection("❌ Failed to enable voice processing: \(error)")
                // Continue without voice processing - STT will work but may miss quiet speech
            }
        } else {
            AppLogger.standard("ℹ️ Voice processing disabled (WakeWordConstants.useVoiceProcessing = false)")
        }

        // Initialize resampler if hardware isn't 16kHz
        if abs(format.sampleRate - 16000.0) > 0.1 {
            do {
                resampler = try Resampler(inputFormat: format, targetSampleRate: 16000)
                AppLogger.verbose("🔄 Resampler initialized: \(format.sampleRate)Hz → 16kHz")
            } catch {
                AppLogger.connection("❌ Failed to create resampler: \(error)")
                // Continue without resampler - STT will still work, just not at optimal 16kHz
            }
        }

        // Initialize 5-second ring buffer at 16kHz (Phase 2: Ring buffer upgrade)
        // This replaces the old 0.35s pre-roll buffer with a unified buffer that supports
        // both PTT (0.35s pre-roll) and future wake word detection (1.0s pre-roll)
        if audioRingBuffer == nil {
            audioRingBuffer = WakeAudioBuffer(durationSeconds: 5.0, sampleRate: 16000)
            let memoryKB = (5.0 * 16000.0 * 4.0) / 1024.0  // 5s × 16kHz × 4 bytes/float
            AppLogger.verbose("🔄 5-second ring buffer initialized (~\(Int(memoryKB))KB)")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Resample to 16kHz if needed (Phase 1: Audio pipeline migration)
            let buffer16k: AVAudioPCMBuffer
            if let resampler = self.resampler {
                do {
                    buffer16k = try resampler.resample(buffer)
                } catch {
                    AppLogger.connection("⚠️ Resampling failed: \(error)")
                    return  // Drop this frame
                }
            } else {
                buffer16k = buffer  // Already 16kHz
            }

            // Feed unified ring buffer (Phase 2: Ring buffer upgrade)
            // Converts to float samples and writes to 5-second circular buffer
            let samples = self.convertToFloatSamples(buffer16k)
            self.audioRingBuffer?.write(samples)

            // Feed to STT if recording (using 16kHz buffer)
            if self.isRecording, let request = self.recognitionRequest {
                request.append(buffer16k)
            }

            // Phase 3: Feed wake word engine (always feed to keep buffers warm)
            // The engine continues processing audio even during recording/TTS to prevent
            // "cold start" spikes when resuming. The handleWakeDetected() callback handles
            // blocking actual wake triggers based on recordingState and isTTSSpeaking.
            if self.isWakeWordEnabled,
               let engine = self.wakeWordEngine {
                // OpenWakeWordEngine expects AVAudioPCMBuffer
                engine.feed(buffer: buffer16k)

                // Update debug visualization (DEBUG builds only)
                // Dispatch to main thread to avoid blocking audio processing
                #if DEBUG
                let score = engine.currentScore
                let vadActive = engine.vadProbability >= 0.30
                DispatchQueue.main.async {
                    self.wakeWordScore = score
                    if !self.isRecording {
                        self.vadSpeechPresent = vadActive
                    }
                }
                #endif
            }

            // iOS 26: Feed SpeechAnalyzer via AsyncStream continuation
            // Only feed when analyzer is actively recording AND continuation is valid
            // SpeechAnalyzer requires Int16 PCM format, so convert from Float32
            // CRITICAL: Capture continuation locally to avoid race with finalizeSpeech()
            if self.isRecording {
                if let continuation = self.audioInputStream {
                    // Convert float samples to Int16 for SpeechAnalyzer
                    let samples = self.convertToFloatSamples(buffer16k)
                    if let int16Buffer = self.convertFloatToInt16PCMBuffer(samples, sampleRate: 16000) {
                        continuation.yield(AnalyzerInput(buffer: int16Buffer))

                        // Log every 100 buffers to verify audio feeding (DEBUG)
                        #if DEBUG
                        if arc4random_uniform(100) == 0 {
                            let duration = Double(int16Buffer.frameLength) / 16000.0
                            AppLogger.standard("🔊 Audio→SpeechAnalyzer: \(int16Buffer.frameLength) frames (\(String(format: "%.3f", duration))s)")
                        }
                        #endif
                    }
                } else {
                    // DEBUG: Log when continuation is nil but should be recording
                    #if DEBUG
                    if arc4random_uniform(100) == 0 {
                        AppLogger.standard("⚠️ isRecording=true but audioInputStream is nil!")
                    }
                    #endif
                }
            }

            // Phase 3: VAD endpointing is now handled by SpeechDetector (iOS 26)
            // Silero VAD still runs for debug visualization only
            // Endpointing is triggered by handleVADResult() from SpeechDetector results
            #if DEBUG
            if self.vadEndpointingActive, let vad = self.sileroVAD {
                // Silero VAD expects float samples - run for debug visualization
                let vadProb = vad.process(samples: samples)
                if self.isRecording {
                    let vadActive = vadProb >= 0.30
                    DispatchQueue.main.async {
                        self.vadSpeechPresent = vadActive
                    }
                }
            }
            #endif
        }
        hasInstalledTap = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isHotMicActive = true
            AppLogger.standard("🎤 Hot mic audio engine started successfully")
        } catch {
            AppLogger.connection("Failed to start hot mic engine: \(error)")
        }
    }
    
    private func copyBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        dst.frameLength = src.frameLength
        let channels = Int(src.format.channelCount)
        for ch in 0..<channels {
            if let s = src.floatChannelData?[ch], let d = dst.floatChannelData?[ch] {
                memcpy(d, s, Int(src.frameLength) * MemoryLayout<Float>.size)
            }
        }
        return dst
    }

    /// Convert AVAudioPCMBuffer to float samples for ring buffer
    /// Extracts mono channel (takes first channel if multi-channel)
    private func convertToFloatSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)

        var samples: [Float] = []
        samples.reserveCapacity(frameLength)

        // Take mono channel (first channel if multi-channel)
        for frame in 0..<frameLength {
            samples.append(channelData[0][frame])
        }

        return samples
    }

    /// Convert float samples back to AVAudioPCMBuffer for STT
    /// Creates a mono Float32 buffer at the specified sample rate
    private func convertFloatToAVAudioPCMBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: false)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                channelData.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        return buffer
    }

    /// Convert float samples to Int16 PCM buffer for SpeechAnalyzer
    /// SpeechAnalyzer requires 16-bit signed integer audio data
    private func convertFloatToInt16PCMBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: false)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.int16ChannelData?[0] {
            // Convert Float32 [-1.0, 1.0] to Int16 [-32768, 32767]
            for i in 0..<samples.count {
                let sample = max(-1.0, min(1.0, samples[i]))  // Clamp to valid range
                channelData[i] = Int16(sample * 32767.0)
            }
        }

        return buffer
    }
    
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    AppLogger.standard("🎙️ Speech recognition authorized")
                    self?.isAuthorized = true
                    self?.prepareAudioEngine()
                case .denied, .restricted, .notDetermined:
                    AppLogger.connection("⚠️ Speech recognition not authorized: \(authStatus.rawValue)")
                    self?.isAuthorized = false
                @unknown default:
                    AppLogger.connection("⚠️ Speech recognition unknown authorization status")
                    self?.isAuthorized = false
                }
            }
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    AppLogger.connection("⚠️ Microphone permission denied")
                    self?.isAuthorized = false
                } else {
                    AppLogger.verbose("🎙️ Microphone permission granted")
                }
            }
        }
    }
    
    func startRecording() {
        guard isAuthorized else {
            AppLogger.connection("Speech recognition not authorized")
            return
        }

        guard !isRecording else { return }

        guard !requiresSiriEnablement else {
            AppLogger.connection("⚠️ Siri & Dictation required before starting speech recognition")
            return
        }

        // Phase 3: Check if this is a PTT button press (vs wake word trigger)
        if recordingState != .recordingWake {
            // PTT mode
            recordingState = .recordingPTT
            vadEndpointingActive = false

            // Debounce button presses
            let now = Date().timeIntervalSince1970
            if now - lastButtonPressTime < 0.5 {
                AppLogger.verbose("🎤 Button press debounced (\(Int((now - lastButtonPressTime) * 1000))ms too soon)")
                return
            }
            lastButtonPressTime = now
        }

        // Properly clean up any existing tasks and audio engine
        cleanupRecognition()

        // Start recording immediately - no delay needed with pre-warmed engine
        performStartRecording()
    }
    
    private func cleanupRecognition() {
        #if DEBUG
        AppLogger.verbose("🔧 [DEBUG] cleanupRecognition() START - recognitionTask=\(recognitionTask != nil ? "exists" : "nil"), recognitionRequest=\(recognitionRequest != nil ? "exists" : "nil"), hasAttemptedFallback=\(hasAttemptedFallback)")
        #endif

        // Stop timer if running
        finalizationTimer?.invalidate()
        finalizationTimer = nil

        // Reset states
        isProcessing = false
        accumulatedText = ""
        lastSegment = ""
        actualPreRollDuration = 0.0
        actualPreRollSampleCount = 0
        // NOTE: wakeWordSampleIndex and ringBufferSampleCountAtWake are NOT reset here
        // They are set by onWakeEvent BEFORE cleanupRecognition is called, and must persist
        // through the recording session for filterWakeWordByTiming() to use them

        // Keep engine + tap alive for hot mic (avoid cold-start penalty)

        // Clean up speech recognition task
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // iOS 26: Clean up previous session's SpeechAnalyzer state
        // CRITICAL: Must finish old stream BEFORE creating new one in next session
        // Otherwise the old finalizationTimer could finish the new session's stream!
        if let continuation = audioInputStream {
            continuation.finish()
            audioInputStream = nil
            audioInputStreamSequence = nil
            AppLogger.verbose("🔄 Previous audio input stream finished during cleanup")
        }

        // Cancel any pending analyzer tasks from previous session
        analyzerTask?.cancel()
        analyzerTask = nil
        transcriberTask?.cancel()
        transcriberTask = nil

        // Clear per-session references (will be recreated for new session)
        currentAnalyzer = nil
        currentTranscriber = nil

        // Clear completion handler
        speechCompletionHandler = nil

        // Reset cloud fallback flag for next recording session
        hasAttemptedFallback = false

        #if DEBUG
        AppLogger.verbose("🔧 [DEBUG] cleanupRecognition() END - all state cleared, hasAttemptedFallback reset to false")
        #endif

        // NOTE: We keep audio session active between recordings for hot mic performance
        // This is OK when app is active, but fullTeardown() deactivates for battery savings
        // when app backgrounds or device sleeps

        // Engine stays prepared for next use - no need to re-initialize
    }
    
    /// Complete teardown for app backgrounding or user disconnect
    func fullTeardown() {
        cleanupRecognition()

        // Stop hot mic engine to save battery
        if audioEngine.isRunning {
            audioEngine.stop()
            isHotMicActive = false
            AppLogger.verbose("🛑 Hot mic audio engine stopped")
        }

        // Now deactivate the audio session completely
        // CRITICAL: This allows iPhone to sleep and saves massive battery drain
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            AppLogger.verbose("🔇 Audio session fully deactivated for battery savings")
        } catch {
            AppLogger.connection("Failed to deactivate audio session: \(error)")
        }
    }
    
    private func performStartRecording() {
            // Ensure audio session is active (may already be active from previous recording)
            let audioSession = AVAudioSession.sharedInstance()

            #if DEBUG
            AppLogger.verbose("🔧 [DEBUG] performStartRecording() START - category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
            #endif

            do {
                // Keep .playAndRecord category to maintain hot mic tap (don't switch to .record!)
                // Switching categories would stop the audio engine and kill the hot mic tap
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                )
                // Re-assert 16kHz sample rate preference (in case it was changed)
                try audioSession.setPreferredSampleRate(16000.0)
                // Activate session if not already active (idempotent operation)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

                #if DEBUG
                AppLogger.verbose("🔧 [DEBUG] Audio session configured - category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
                #endif
            } catch {
                AppLogger.connection("Failed to setup audio session: \(error)")
                return
            }

            // iOS 26: Use SpeechTranscriber (word timestamps + native VAD syncing)
            startSpeechTranscriberRecording()
    }

    // MARK: - Legacy SFSpeechRecognizer (Deprecated - kept for reference)
    // This legacy method is no longer called. It's preserved for debugging/comparison.
    // The app now uses SpeechTranscriber exclusively (iOS 26.0 minimum deployment).
    private func performStartRecording_LEGACY() {

            // Reset fallback flag for new recording session
            if !isRecording {
                hasAttemptedFallback = false
            }

            // Ensure audio session is active (may already be active from previous recording)
            let audioSession = AVAudioSession.sharedInstance()

            #if DEBUG
            AppLogger.verbose("🔧 [DEBUG] performStartRecording() START - category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue), hasAttemptedFallback=\(hasAttemptedFallback), recognitionRequest=\(recognitionRequest != nil ? "EXISTS (ZOMBIE!)" : "nil")")
            #endif

            do {
                // Keep .playAndRecord category to maintain hot mic tap (don't switch to .record!)
                // Switching categories would stop the audio engine and kill the hot mic tap
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                )
                // Re-assert 16kHz sample rate preference (in case it was changed)
                try audioSession.setPreferredSampleRate(16000.0)
                // Activate session if not already active (idempotent operation)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

                #if DEBUG
                AppLogger.verbose("🔧 [DEBUG] Audio session configured - category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
                #endif
            } catch {
                AppLogger.connection("Failed to setup audio session: \(error)")
                return
            }
            
            // Create recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                AppLogger.connection("Unable to create recognition request")
                return
            }
            
            recognitionRequest.shouldReportPartialResults = true

            // Option 1: Gaming vocabulary hints for better ASR accuracy
            recognitionRequest.contextualStrings = RetroGamingVocabulary.terms
            AppLogger.standard("🎮 Applied \(RetroGamingVocabulary.terms.count) contextual gaming terms")

            // Add diagnostic logging for speech recognizer capabilities
            updateSpeechRecognizerLocale()
            guard let recognizer = speechRecognizer else {
                AppLogger.connection("No compatible speech recognizer available for current locale")
                stopRecording()
                return
            }

            if let recognizer = speechRecognizer {
                AppLogger.verbose("🎙️ Speech recognizer available: \(recognizer.isAvailable)")
                AppLogger.verbose("🎙️ Supports on-device: \(recognizer.supportsOnDeviceRecognition)")
                AppLogger.verbose("🎙️ Locale: \(recognizer.locale.identifier)")
            }

            // Standard iOS speech recognition pattern: trust supportsOnDeviceRecognition
            if #available(iOS 13.0, *) {
                let supportsOnDevice = recognizer.supportsOnDeviceRecognition
                // Only use on-device if we haven't fallen back yet
                recognitionRequest.requiresOnDeviceRecognition = supportsOnDevice && !hasAttemptedFallback

                if supportsOnDevice && !hasAttemptedFallback {
                    AppLogger.standard("✅ Using on-device speech recognition for faster performance")
                } else if hasAttemptedFallback {
                    AppLogger.standard("🌐 Using server-based speech recognition (cloud fallback)")
                } else {
                    AppLogger.standard("🌐 Using server-based speech recognition")
                }
            }
            // Hint: real-time dictation/commands
            recognitionRequest.taskHint = .dictation

            // Apply gaming pronunciation model (iOS 17+)
            if #available(iOS 17.0, *), let modelURL = gamingModelURL {
                let config = SFSpeechLanguageModel.Configuration(languageModel: modelURL)
                recognitionRequest.customizedLanguageModel = config
                AppLogger.standard("🎮 Gaming pronunciation model applied")
            }

            // Set up audio engine (input node should be pre-warmed)
            do {
                // Ensure hot mic session is active/unmuted
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                audioEngine.inputNode.isVoiceProcessingInputMuted = false

                isRecording = true
                transcription = ""
                accumulatedText = ""
                lastSegment = ""

                // Initialize ASR failsafe timer
                lastTranscriptionUpdateTime = Date().timeIntervalSince1970
                lastTranscriptionText = ""

                // Extract pre-roll from ring buffer (Phase 2 & 3: Ring buffer upgrade)
                // PTT mode: 0.35s pre-roll (same as before)
                // Wake word mode: 1.5s pre-roll (includes "Hey Mister" + fast-spoken commands)
                // 1.5s captures ~0.24s wake word detection delay + 1.26s for "Let's play MegaMan 3"
                let preRollDuration: Double = (recordingState == .recordingWake) ? 1.5 : 0.35

                if let preRollSamples = audioRingBuffer?.readLast(seconds: preRollDuration) {
                    // Convert float samples back to AVAudioPCMBuffer for STT
                    if let preRollBuffer = convertFloatToAVAudioPCMBuffer(preRollSamples, sampleRate: 16000) {
                        recognitionRequest.append(preRollBuffer)
                        let actualDuration = Double(preRollSamples.count) / 16000.0
                        AppLogger.verbose("🎤 Fed \(String(format: "%.2f", actualDuration))s pre-roll from ring buffer (\(recordingState), \(preRollSamples.count) samples)")
                    } else {
                        AppLogger.connection("⚠️ Failed to convert pre-roll samples to buffer")
                    }
                } else {
                    AppLogger.connection("⚠️ No pre-roll available in ring buffer - hot mic may not be running")
                }

                // Start recognition with better error handling
                recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                    DispatchQueue.main.async {
                        guard let self = self else { return }

                        if let result = result {
                            let currentSegment = result.bestTranscription.formattedString

                            AppLogger.verbose("🎤 Speech result: isFinal=\(result.isFinal), segment=\"\(currentSegment)\", accumulated=\"\(self.accumulatedText)\"")

                            // Track ASR updates for failsafe timeout (noisy environment protection)
                            // If transcription changes, update the timestamp
                            let currentTranscription = self.accumulatedText + " " + currentSegment
                            if currentTranscription.trimmingCharacters(in: .whitespaces) != self.lastTranscriptionText.trimmingCharacters(in: .whitespaces) {
                                self.lastTranscriptionUpdateTime = Date().timeIntervalSince1970
                                self.lastTranscriptionText = currentTranscription
                            }

                            if result.isFinal {
                                // Final result: accumulate this segment (if not empty)
                                if !currentSegment.isEmpty {
                                    if !self.accumulatedText.isEmpty {
                                        self.accumulatedText += " " + currentSegment
                                    } else {
                                        self.accumulatedText = currentSegment
                                    }
                                    self.transcription = self.stripWakeWord(self.accumulatedText)
                                    AppLogger.verbose("🎤 Final accumulated: \"\(self.accumulatedText)\"")
                                } else {
                                    // Empty final result - combine everything we have
                                    if !self.accumulatedText.isEmpty && !self.lastSegment.isEmpty {
                                        // Both exist - combine them
                                        self.transcription = self.stripWakeWord(self.accumulatedText + " " + self.lastSegment)
                                        AppLogger.verbose("🎤 Empty final result, combined: \"\(self.transcription)\"")
                                    } else if !self.accumulatedText.isEmpty {
                                        // Only accumulated text
                                        self.transcription = self.stripWakeWord(self.accumulatedText)
                                        AppLogger.verbose("🎤 Empty final result, keeping accumulated: \"\(self.accumulatedText)\"")
                                    } else if !self.lastSegment.isEmpty {
                                        // Only last segment
                                        self.transcription = self.stripWakeWord(self.lastSegment)
                                        AppLogger.verbose("🎤 Empty final result, keeping last segment: \"\(self.lastSegment)\"")
                                    } else if !self.transcription.isEmpty {
                                        // Keep existing transcription
                                        AppLogger.verbose("🎤 Empty final result, keeping last transcription: \"\(self.transcription)\"")
                                    }
                                }

                                // Clear lastSegment since we're done with this recognition
                                self.lastSegment = ""

                                // If we're in processing state, finalize immediately
                                if self.isProcessing {
                                    self.finalizeSpeech()
                                    return
                                }
                            } else {
                                // Partial result: check if iOS started a new segment
                                // Compare against lastSegment (not transcription which includes accumulated text)
                                let isNewSegment = !self.lastSegment.isEmpty &&
                                                   !currentSegment.isEmpty &&
                                                   currentSegment.count < self.lastSegment.count / 2 &&
                                                   !self.lastSegment.lowercased().contains(currentSegment.lowercased().prefix(min(10, currentSegment.count)))

                                if isNewSegment {
                                    // iOS started a new segment, auto-accumulate the previous segment
                                    if !self.accumulatedText.isEmpty {
                                        self.accumulatedText += " " + self.lastSegment
                                    } else {
                                        self.accumulatedText = self.lastSegment
                                    }
                                    self.lastSegment = ""  // Clear since we just accumulated it
                                    AppLogger.verbose("🎤 New segment detected, auto-accumulated: \"\(self.accumulatedText)\"")
                                }

                                // Update lastSegment with current partial
                                self.lastSegment = currentSegment

                                // Show accumulated + current partial segment
                                if !self.accumulatedText.isEmpty {
                                    self.transcription = self.stripWakeWord(self.accumulatedText + " " + currentSegment)
                                } else {
                                    self.transcription = self.stripWakeWord(currentSegment)
                                }
                            }
                        }
                        
                        // Handle errors more gracefully - only stop on critical errors
                        if let error = error {
                            let nsError = error as NSError

                            #if DEBUG
                            AppLogger.verbose("🔧 [DEBUG] Recognition error - domain=\(nsError.domain), code=\(nsError.code), hasAttemptedFallback=\(self.hasAttemptedFallback), recognitionTask=\(self.recognitionTask != nil ? "exists" : "nil")")
                            #endif

                            // Check for on-device unavailability errors and attempt cloud fallback
                            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 && !self.hasAttemptedFallback {
                                AppLogger.standard("🌐 On-device speech unavailable, falling back to cloud")
                                self.hasAttemptedFallback = true

                                #if DEBUG
                                AppLogger.verbose("🔧 [DEBUG] Error 1101 fallback - BEFORE cleanup: recognitionTask=\(self.recognitionTask != nil ? "exists" : "nil"), recognitionRequest=\(self.recognitionRequest != nil ? "exists" : "nil")")
                                #endif

                                // CRITICAL FIX: Block cloud fallback if user has released button
                                // During button spam, error callback might fire AFTER user released button.
                                // Starting a new recording session would desynchronize the state machine.
                                // Check if we're still in PTT recording mode before restarting.
                                if self.recordingState != .recordingPTT && self.recordingState != .recordingWake {
                                    AppLogger.verbose("🛑 Blocking cloud fallback: User already released button (state: \(self.recordingState))")
                                    return
                                }

                                // Restart with cloud-based recognition
                                self.cleanupRecognition()

                                #if DEBUG
                                AppLogger.verbose("🔧 [DEBUG] Error 1101 fallback - AFTER cleanup, BEFORE restart")
                                #endif

                                self.performStartRecording()
                                return
                            }

                            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
                                #if DEBUG
                                AppLogger.verbose("🔧 [DEBUG] Error 1101 - already attempted fallback, calling handleMissingSiriAssets()")
                                #endif
                                self.handleMissingSiriAssets()
                                return
                            }
                            AppLogger.connection("Speech recognition error: \(error)")
                            if self.isProcessing {
                                self.finalizeSpeech()
                            } else {
                                self.stopRecording()
                            }
                        }
                        // Note: In PTT mode, we do NOT auto-stop on isFinal.
                        // User controls when to stop by releasing the button.
                        // isFinal just means iOS finished processing a segment, but user may continue speaking.
                    }
                }
            } catch {
                AppLogger.connection("Failed to start audio engine: \(error)")
                stopRecording()
            }
    }
    
    func setSpeechCompletionHandler(_ handler: @escaping () -> Void) {
        speechCompletionHandler = handler
    }

    /// Reset recording state to idle (called after AI processing completes or is cancelled)
    func resetToIdle() {
        recordingState = .idle

        // CRITICAL: Reset wake word processing flag here - this is the ONLY place it should be reset
        // This ensures we block wake word triggers during the entire AI processing cycle
        isProcessingWakeWord = false

        AppLogger.standard("🔄 Recording state reset to .idle (ready for next wake word)")
    }

    /// Prepare for manual text input by ensuring clean recognition state
    /// Called before bypassing speech recognition with manual text entry
    /// This prevents state corruption that can break subsequent PTT recordings
    /// Bug: Without this cleanup, manual text input can leave recognitionRequest/recognitionTask
    /// in an inconsistent state, causing subsequent PTT recordings to fail with error 1110
    func prepareForManualTextInput() {
        // Stop any active recording
        if isRecording {
            isRecording = false
            isProcessing = false
            recognitionRequest?.endAudio()
        }

        // Clean up recognition components (critical for preventing state corruption)
        cleanupRecognition()

        // Reset state machine
        recordingState = .idle
        vadEndpointingActive = false

        // Note: We do NOT clear transcription here - caller will set it to manual text input
        // Only clear accumulated/segment buffers (these are internal recognition state)
        accumulatedText = ""
        lastSegment = ""

        AppLogger.verbose("🔄 Speech recognition state cleaned for manual text input")
    }
    
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        isProcessing = true

        // NOTE: Do NOT reset isProcessingWakeWord here - it should stay true until
        // resetToIdle() is called after AI processing completes. This prevents
        // duplicate wake word triggers while the AI is still processing.

        // CRITICAL FIX: Reset recordingState immediately to prevent stuck-green bug
        // If finalization timer gets cancelled (e.g., during button spam or fallback),
        // recordingState must still reset. Previously this only happened in finalizeSpeech().
        // Moving it here ensures state machine always resets even if timer is cancelled.
        if recordingState == .recordingPTT || recordingState == .recordingWake {
            let previousState = recordingState
            recordingState = .idle
            AppLogger.verbose("🔄 Recording state reset: \(previousState) → .idle")
        }

        // Reset debug visualization
        #if DEBUG
        vadSpeechPresent = false
        #endif

        // Phase 3: Disable VAD endpointing when stopping
        vadEndpointingActive = false

        // iOS 26: Finish audio input stream to signal end-of-audio
        // CRITICAL: This signals the analyzer to process remaining audio and emit final results
        if audioInputStream != nil {
            AppLogger.verbose("🔄 Finishing audio input stream to flush SpeechTranscriber results...")
            audioInputStream?.finish()
            audioInputStream = nil
            audioInputStreamSequence = nil
        }

        // Finalize the analyzer to flush any pending results
        // Must call finalizeAndFinishThroughEndOfInput() to get final transcription
        if let analyzer = currentAnalyzer {
            Task {
                do {
                    AppLogger.verbose("🔄 Finalizing SpeechAnalyzer...")
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    await MainActor.run {
                        AppLogger.verbose("✅ SpeechAnalyzer finalized")
                    }
                } catch {
                    await MainActor.run {
                        AppLogger.connection("SpeechAnalyzer finalization error: \(error)")
                    }
                }
            }
        }

        detectorTask?.cancel()
        detectorTask = nil

        // Reset UI timer when recording stops
        Task { @MainActor in
            uiStateService?.resetTimer()
        }

        // Signal end of audio input but keep recognition task running
        recognitionRequest?.endAudio()

        // Keep hot mic running; do not stop engine or remove tap

        // Start timeout timer for final transcription (3 seconds)
        finalizationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.finalizeSpeech()
            }
        }

        // Keep audio session active to avoid re-activation delays
    }
    
    private func finalizeSpeech() {
        finalizationTimer?.invalidate()
        finalizationTimer = nil
        isProcessing = false

        // Clean up recognition task
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil

        // iOS 26: Clean up SpeechAnalyzer tasks and input stream
        // CRITICAL: Finish continuation BEFORE cancelling tasks to prevent race condition
        if let continuation = audioInputStream {
            continuation.finish()
            audioInputStream = nil
            audioInputStreamSequence = nil
            AppLogger.verbose("🔄 Audio input stream finished and cleared")
        }

        // Cancel all analyzer-related tasks
        analyzerTask?.cancel()
        analyzerTask = nil
        detectorTask?.cancel()
        detectorTask = nil
        transcriberTask?.cancel()
        transcriberTask = nil

        // Clear per-session analyzer and transcriber references
        // (they cannot be reused - new ones created for next session)
        currentAnalyzer = nil
        currentTranscriber = nil

        // Only transition to processing state if we have actual transcription
        // This prevents button staying red after short taps (e.g., tapping to stop TTS)
        if !transcription.isEmpty && !displayTranscription.isEmpty {
            // Transition to processing state BEFORE calling handler
            // This allows user to cancel AI request by tapping the RED STOP button
            recordingState = .processingRequest
            AppLogger.verbose("🔄 State transition: .idle → .processingRequest (AI request in flight)")
        } else {
            // No transcription - keep state as .idle (button stays blue)
            // Common case: User tapped PTT briefly to stop TTS playback, or ASR returned nothing
            AppLogger.standard("🔄 No transcription detected - resetting to idle (ready for next wake word)")

            // CRITICAL: Reset isProcessingWakeWord here since there's no AI processing
            // Without transcription, resetToIdle() won't be called by the AI flow
            isProcessingWakeWord = false
        }

        // Call completion handler (triggers AI processing in ConsumerView)
        if let handler = speechCompletionHandler {
            handler()
            // Note: We don't clear speechCompletionHandler - it's set on every view render in ContentView
        } else {
            AppLogger.connection("⚠️ No speech completion handler set! This should never happen.")
            // Safety: Reset to idle if no handler exists
            recordingState = .idle
        }

        // Update lastWakeTime to prevent immediate re-trigger after wake word session ends
        // This extends the refractory period from when the session COMPLETES, not just when it starts
        lastWakeTime = Date().timeIntervalSince1970

        // NOTE: Do NOT reset isProcessingWakeWord here - it should stay true until
        // resetToIdle() is called after AI processing completes. This prevents
        // duplicate wake word triggers while the AI is still processing.
    }

    // MARK: - Wake Word System (Phase 3)

    /// Initialize wake word detection engine
    private func initializeWakeWord() {
        guard let modelPath = Bundle.main.path(forResource: "hey_mister_V7_baseline_epoch_50", ofType: "onnx"),
              let melPath = Bundle.main.path(forResource: "melspectrogram", ofType: "onnx"),
              let embPath = Bundle.main.path(forResource: "embedding_model", ofType: "onnx") else {
            AppLogger.connection("❌ Wake word models not found in bundle")
            isWakeWordEnabled = false
            return
        }

        // Initialize OpenWakeWord engine
        wakeWordEngine = OpenWakeWordEngine(
            modelPath: modelPath,
            melSpectrogramPath: melPath,
            embeddingModelPath: embPath
        )

        // Capture sample position from wake word event (called immediately, NOT on main thread)
        // This runs BEFORE the main onWake callback, so we can store the sample index
        wakeWordEngine?.onWakeEvent = { [weak self] event in
            guard let self = self else { return }
            // Capture sample index from event (Sendable-safe)
            let sampleIdx = event.sampleIndex

            // Dispatch to main thread to access MainActor-isolated properties
            DispatchQueue.main.async {
                let ringBufferCount = self.audioRingBuffer?.getTotalSamplesWritten() ?? 0
                self.wakeWordSampleIndex = sampleIdx
                self.ringBufferSampleCountAtWake = ringBufferCount
                AppLogger.verbose("📍 Wake word event captured (sampleIndex: \(sampleIdx), ringBuffer: \(ringBufferCount))")
            }
        }

        // Set wake detection callback (runs on main thread via DispatchQueue.main.async in engine)
        // NOTE: This callback runs AFTER onWakeEvent, so sample positions are already stored
        wakeWordEngine?.onWake = { [weak self] in
            guard let self = self else { return }

            // CRITICAL: Use objc_sync to ensure atomic check-and-set of isProcessingWakeWord
            // Without this, multiple callbacks can pass the guard before any sets the flag
            var shouldProcess = false
            objc_sync_enter(self)
            if !self.isProcessingWakeWord && !self.isRecording && self.recordingState == .idle {
                self.isProcessingWakeWord = true
                shouldProcess = true
            }
            objc_sync_exit(self)

            guard shouldProcess else {
                AppLogger.verbose("🎤 Wake word callback ignored (already processing or recording)")
                return
            }

            AppLogger.standard("🎤 Wake word callback fired, dispatching to MainActor...")

            Task { @MainActor in
                self.handleWakeDetected()
            }
        }

        // Initialize Silero VAD
        sileroVAD = SileroVAD()

        // Start engine
        do {
            try wakeWordEngine?.start()
            AppLogger.standard("✅ Wake word initialized: \"Hey Mister\"")
        } catch {
            AppLogger.connection("❌ Failed to start wake word engine: \(error)")
            isWakeWordEnabled = false
            return
        }

        // Enable screen management (keep awake + brightness control)
        #if os(iOS)
        // Save user's current brightness
        originalBrightness = UIScreen.main.brightness
        AppLogger.verbose("💾 Saved original brightness: \(originalBrightness)")

        // Prevent device from sleeping
        UIApplication.shared.isIdleTimerDisabled = true
        AppLogger.standard("📱 Screen sleep disabled (wake word mode active)")

        // Start dim timer (30 seconds of inactivity)
        startDimTimer()
        #endif
    }

    /// Teardown wake word detection engine
    private func teardownWakeWord() {
        wakeWordEngine?.stop()
        wakeWordEngine = nil
        sileroVAD = nil
        vadEndpointingActive = false
        AppLogger.standard("🛑 Wake word disabled (ONNX processing stopped)")

        // Disable screen management (restore sleep + brightness)
        #if os(iOS)
        // Stop dim timer
        dimTimer?.invalidate()
        dimTimer = nil

        // Restore original brightness (if screen was dimmed)
        if isDimmed {
            UIScreen.main.brightness = originalBrightness
            isDimmed = false
            AppLogger.verbose("☀️ Brightness restored to original: \(originalBrightness)")
        }

        // Re-enable device sleep
        UIApplication.shared.isIdleTimerDisabled = false
        AppLogger.standard("📱 Screen sleep re-enabled (wake word mode disabled)")
        #endif
    }

    // MARK: - iOS 26 SpeechAnalyzer Setup

    /// Initialize iOS 26 SpeechDetector for VAD endpointing
    /// NOTE: SpeechAnalyzer and SpeechTranscriber are created FRESH per recording session
    /// because they cannot be reused after finalization
    private func setupSpeechAnalyzer() async {
        // Create SpeechDetector for VAD with results reporting enabled
        // NOTE: Results must be enabled via init(detectionOptions:reportResults:)
        // Using .medium sensitivity (recommended for most use cases)
        // Options: .low (more forgiving), .medium (recommended), .high (more aggressive)
        let detectionOptions = SpeechDetector.DetectionOptions(sensitivityLevel: .medium)
        let detector = SpeechDetector(detectionOptions: detectionOptions, reportResults: true)

        await MainActor.run {
            self.speechDetector = detector
            AppLogger.standard("✅ SpeechDetector initialized for VAD endpointing (reportResults: true)")
        }

        // Pre-download speech model at startup (avoids delay on first recording)
        await preDownloadSpeechModel()

        // Pre-warm the analyzer pipeline (fixes first wake word failure)
        await preWarmSpeechAnalyzer()
    }

    /// Pre-download speech model assets at app startup
    /// This avoids the delay when first wake word or PTT recording starts
    private func preDownloadSpeechModel() async {
        // Use supported locale (iOS 26 requirement)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            await MainActor.run {
                AppLogger.connection("⚠️ Current locale not supported - speech model not pre-downloaded")
            }
            return
        }

        // Create a temporary transcriber just to check/download assets
        let tempTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [tempTranscriber]) {
                await MainActor.run {
                    AppLogger.standard("🔄 Pre-downloading speech model for locale: \(locale.identifier)...")
                }
                try await request.downloadAndInstall()
                await MainActor.run {
                    AppLogger.standard("✅ Speech model pre-downloaded for locale: \(locale.identifier)")
                }
            } else {
                await MainActor.run {
                    AppLogger.standard("✅ Speech model already available for locale: \(locale.identifier)")
                }
            }
        } catch {
            await MainActor.run {
                AppLogger.connection("⚠️ Failed to pre-download speech model: \(error)")
            }
        }
    }

    /// Pre-warm the SpeechAnalyzer pipeline by running a quick dummy analysis
    /// This ensures the analyzer is fully initialized before first real use
    /// Fixes: First wake word fails, second works (cold start issue)
    private func preWarmSpeechAnalyzer() async {
        let t0 = Date()
        await MainActor.run {
            AppLogger.standard("🔥 Pre-warming SpeechAnalyzer pipeline...")
        }

        // Create fresh transcriber + analyzer (same as real recording)
        guard let (warmupTranscriber, warmupAnalyzer) = await createFreshTranscriberAndAnalyzer() else {
            await MainActor.run {
                AppLogger.connection("⚠️ Failed to create warmup transcriber/analyzer")
            }
            return
        }

        // Create a tiny stream with silence
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Start result consumer (will complete quickly with no results)
        let consumerTask = Task {
            for try await _ in warmupTranscriber.results {
                // Discard any results (shouldn't be any from silence)
            }
        }

        // Start analyzer in background
        let analyzerTask = Task {
            try? await warmupAnalyzer.start(inputSequence: inputStream)
        }

        // Brief wait for analyzer to initialize
        try? await Task.sleep(for: .milliseconds(100))

        // Feed a tiny bit of silence (100ms @ 16kHz = 1600 samples)
        let silenceSamples = [Int16](repeating: 0, count: 1600)
        let silenceData = silenceSamples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        // Create Int16 PCM buffer from silence
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        if let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600) {
            silenceBuffer.frameLength = 1600
            silenceData.withUnsafeBytes { rawBuffer in
                if let samples = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) {
                    memcpy(silenceBuffer.int16ChannelData![0], samples, 1600 * MemoryLayout<Int16>.size)
                }
            }
            inputContinuation.yield(AnalyzerInput(buffer: silenceBuffer))
        }

        // Brief wait then finish stream
        try? await Task.sleep(for: .milliseconds(100))
        inputContinuation.finish()

        // Wait for tasks to complete
        try? await Task.sleep(for: .milliseconds(200))
        consumerTask.cancel()
        analyzerTask.cancel()

        let elapsed = Date().timeIntervalSince(t0) * 1000
        await MainActor.run {
            self.isAnalyzerPreWarmed = true
            AppLogger.standard("✅ SpeechAnalyzer pre-warmed in \(Int(elapsed))ms")
        }
    }

    /// Create a fresh SpeechTranscriber and SpeechAnalyzer for a new recording session
    /// Returns (transcriber, analyzer) tuple, or nil if locale not supported
    /// NOTE: Speech model is pre-downloaded at startup via preDownloadSpeechModel()
    private func createFreshTranscriberAndAnalyzer() async -> (SpeechTranscriber, SpeechAnalyzer)? {
        // Use supported locale (iOS 26 requirement)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            await MainActor.run {
                AppLogger.connection("❌ Current locale not supported by SpeechTranscriber")
            }
            return nil
        }

        // Create transcriber with explicit options for optimal streaming
        // - volatileResults: Real-time updates as interpretation improves
        // - fastResults: Biases towards responsiveness (smaller window/chunk size)
        // - audioTimeRange: Word timestamps for wake word filtering
        // NOTE: Speech model was pre-downloaded at startup - no download delay here
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        // Create analyzer with transcriber module only
        // NOTE: Each session needs a fresh analyzer - cannot reuse after finalization
        // NOTE: SpeechDetector cannot be added to modules array due to SDK type conformance issue
        // (SpeechDetector doesn't conform to SpeechModule in current iOS 26 beta)
        // Workaround: Use transcriber volatile results as VAD signal for endpointing
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        await MainActor.run {
            AppLogger.verbose("🔄 Created fresh SpeechAnalyzer with transcriber for locale: \(locale.identifier)")
        }

        return (transcriber, analyzer)
    }

    /// Start periodic silence check for VAD endpointing (called when wake word detected)
    /// Since SpeechDetector can't be added to analyzer due to SDK bug, we use transcription
    /// results as VAD signal (handleTranscriberResult calls handleVADResult on new text)
    /// This timer periodically checks for silence timeout when no new transcription arrives
    private func startSpeechDetectorEndpointing() {
        AppLogger.standard("🎤 Starting VAD endpointing via transcription-based detection...")

        // Use a periodic task to check silence timeout
        // Speech detection happens via handleTranscriberResult updating lastSpeechTime
        detectorTask = Task { [weak self] in
            guard let self = self else { return }

            // Check every 200ms for silence timeout
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))

                await MainActor.run {
                    guard self.vadEndpointingActive else { return }
                    // Call with isSpeech=false to check timeout
                    // (If speech was detected, handleTranscriberResult already called with isSpeech=true)
                    self.handleVADResult(isSpeech: false)
                }
            }
            AppLogger.standard("🔊 VAD endpointing task cancelled")
        }
    }

    /// Handle SpeechDetector VAD results for endpointing
    /// Replaces Silero VAD logic with Apple's native VAD (synced with STT)
    @MainActor
    private func handleVADResult(isSpeech: Bool) {
        guard vadEndpointingActive else { return }

        let now = Date().timeIntervalSince1970
        let timeSinceWakeWord = (now - self.wakeWordDetectedTime) * 1000.0  // ms

        // Update UI timer ring (same as before)
        let elapsed = now - self.wakeWordDetectedTime
        let maxDuration = 5.0
        let timeRemaining = max(0, maxDuration - elapsed)
        uiStateService?.recordingTimeRemaining = timeRemaining
        uiStateService?.recordingMaxDuration = maxDuration

        // Update debug visualization
        #if DEBUG
        if isRecording {
            vadSpeechPresent = isSpeech
        }
        #endif

        // 2-second gate period: Ignore VAD for first 2 seconds after wake word
        // Allows natural pause after "Hey Mister" before command
        let gatePeriodMs = 2000.0

        if timeSinceWakeWord < gatePeriodMs {
            // Still in gate period - keep mic open
            if isSpeech {
                self.lastSpeechTime = now
            }
        } else {
            // Gate period expired - use normal VAD timeout logic
            if isSpeech {
                // Speech detected, reset silence timer
                self.lastSpeechTime = now
            }

            // Check if silence timeout reached
            let silenceDuration = (now - self.lastSpeechTime) * 1000.0  // ms
            let timeoutMs = 1100.0  // Same as Silero VAD (from Constants.swift)

            // ASR Failsafe: Check if ASR hasn't produced new text in 3 seconds
            // Handles noisy environments where VAD stays active but ASR ignores background
            let timeSinceLastASRUpdate = (now - self.lastTranscriptionUpdateTime) * 1000.0
            let asrTimeoutMs = 3000.0

            if silenceDuration > timeoutMs {
                AppLogger.verbose("🎤 SpeechDetector endpointing: \(Int(silenceDuration))ms silence")
                self.stopRecording()
            } else if timeSinceLastASRUpdate > asrTimeoutMs && self.lastTranscriptionUpdateTime > 0 {
                AppLogger.standard("🛡️ ASR failsafe triggered (SpeechDetector mode)")
                self.stopRecording()
            }
            // Removed 5s max recording limit - rely on ASR silence timeout (3s) instead
            // This allows users to speak longer commands without being cut off
        }
    }

    /// Start SpeechTranscriber recording (iOS 26 STT with word timestamps)
    /// Uses start(inputSequence:) for autonomous streaming (not analyzeSequence which blocks)
    private func startSpeechTranscriberRecording() {
        // Reset transcription state FIRST (before async work)
        isRecording = true
        transcription = ""
        accumulatedText = ""
        lastSegment = ""

        // Initialize ASR failsafe timer
        lastTranscriptionUpdateTime = Date().timeIntervalSince1970
        lastTranscriptionText = ""

        // NOTE: audioInputStream is set AFTER analyzer starts to prevent premature feeding
        // The hot mic tap checks for audioInputStream before yielding audio

        // Create fresh transcriber and analyzer asynchronously, then start streaming
        Task { [weak self] in
            guard let self = self else { return }

            // Timing diagnostics for first wake word debugging
            let t0 = Date()
            let isPreWarmed = await MainActor.run { self.isAnalyzerPreWarmed }
            AppLogger.standard("⏱️ T+0ms: Starting transcriber (pre-warmed: \(isPreWarmed))")

            // Create FRESH transcriber + analyzer for this session
            // CRITICAL: Cannot reuse - each session needs new instances
            guard let (freshTranscriber, freshAnalyzer) = await self.createFreshTranscriberAndAnalyzer() else {
                await MainActor.run {
                    AppLogger.connection("❌ Failed to create SpeechTranscriber")
                    self.isRecording = false
                }
                return
            }
            AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Transcriber/analyzer created")

            // Store references for cleanup
            await MainActor.run {
                self.currentTranscriber = freshTranscriber
                self.currentAnalyzer = freshAnalyzer
            }

            // STEP 1: Start result consumer task FIRST (before starting analyzer)
            // This ensures we don't miss any volatile results
            // CRITICAL: Use @MainActor to avoid hop delay between logging and UI update
            self.transcriberTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                AppLogger.standard("🔄 SpeechTranscriber: Result consumer task started, waiting for results...")

                do {
                    var resultCount = 0
                    for try await result in freshTranscriber.results {
                        resultCount += 1
                        let text = String(result.text.characters)
                        let isFinal = result.isFinal
                        AppLogger.standard("📝 Result #\(resultCount) [\(isFinal ? "FINAL" : "VOLATILE")]: \"\(text.isEmpty ? "(empty)" : text)\"")
                        // Now runs synchronously on MainActor - no hop delay
                        self.handleTranscriberResult(result)
                    }
                    AppLogger.standard("🔄 SpeechTranscriber: Result loop completed (\(resultCount) results)")
                } catch {
                    AppLogger.connection("SpeechTranscriber error: \(error)")
                    if self.isProcessing {
                        self.finalizeSpeech()
                    } else {
                        self.stopRecording()
                    }
                }
            }
            AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Result consumer task started")

            // STEP 2: Create audio input stream
            // CRITICAL: Store BOTH the stream AND continuation as instance variables
            // If the stream goes out of scope, it finishes immediately!
            let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            await MainActor.run {
                self.audioInputStreamSequence = inputStream
                self.audioInputStream = inputContinuation
            }
            AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Audio stream created + stored as instance var")

            // STEP 3: Extract pre-roll from ring buffer BEFORE starting analyzer
            // This ensures audio is ready to feed immediately when analyzer starts
            let recordingMode = await MainActor.run { self.recordingState }
            let preRollDuration: Double = (recordingMode == .recordingWake) ? 1.5 : 0.35

            var preRollBuffer: AVAudioPCMBuffer?
            if let preRollSamples = await MainActor.run(body: { self.audioRingBuffer?.readLast(seconds: preRollDuration) }) {
                preRollBuffer = await MainActor.run(body: { self.convertFloatToInt16PCMBuffer(preRollSamples, sampleRate: 16000) })
                let actualDuration = Double(preRollSamples.count) / 16000.0
                let sampleCount = preRollSamples.count
                // Store for wake word timestamp filtering
                await MainActor.run {
                    self.actualPreRollDuration = actualDuration
                    self.actualPreRollSampleCount = sampleCount
                }
                AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Pre-roll prepared (\(String(format: "%.2f", actualDuration))s, \(sampleCount) samples)")
            }

            // STEP 4: Start analyzer in background task
            // CRITICAL: start(inputSequence:) BLOCKS until stream ends (finish() called)
            // So we run it in a separate task and don't await it
            // Use the stored instance variable, not the local variable
            guard let storedStream = await MainActor.run(body: { self.audioInputStreamSequence }) else {
                AppLogger.connection("❌ Audio stream was not stored properly")
                return
            }
            self.analyzerTask = Task {
                do {
                    AppLogger.standard("🔄 SpeechAnalyzer: Calling start(inputSequence:)...")
                    try await freshAnalyzer.start(inputSequence: storedStream)
                    // This only completes when inputStream.finish() is called
                    AppLogger.standard("✅ SpeechAnalyzer.start() completed (stream finished)")
                } catch {
                    await MainActor.run {
                        AppLogger.connection("❌ SpeechAnalyzer error: \(error)")
                    }
                }
            }
            AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Analyzer task launched")

            // Brief yield to allow analyzer task to start processing the input stream
            try? await Task.sleep(for: .milliseconds(50))
            AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Post-sleep (50ms)")

            // STEP 5: Feed pre-roll audio now that analyzer is listening
            if let buffer = preRollBuffer {
                _ = await MainActor.run {
                    self.audioInputStream?.yield(AnalyzerInput(buffer: buffer))
                }
                AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Fed pre-roll to analyzer")
            } else {
                AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: No pre-roll available")
            }

            AppLogger.standard("⏱️ T+\(Int(Date().timeIntervalSince(t0)*1000))ms: Live streaming enabled ✅")
        }
    }

    /// Handle SpeechTranscriber results (volatile/partial and final)
    /// Also serves as VAD signal: any transcription = speech detected
    @MainActor
    private func handleTranscriberResult(_ result: SpeechTranscriber.Result) {
        // Extract plain text from AttributedString
        let currentSegment = String(result.text.characters)

        // Log result type for debugging
        let resultType = result.isFinal ? "FINAL" : "VOLATILE"
        AppLogger.verbose("🎤 SpeechTranscriber [\(resultType)]: \"\(currentSegment)\"")

        // Track ASR updates for failsafe timeout
        let currentTranscription = currentSegment
        if currentTranscription.trimmingCharacters(in: .whitespaces) != self.lastTranscriptionText.trimmingCharacters(in: .whitespaces) {
            self.lastTranscriptionUpdateTime = Date().timeIntervalSince1970
            self.lastTranscriptionText = currentTranscription

            // VAD via transcription: Any new text = speech detected
            // This replaces SpeechDetector which can't be added to analyzer (SDK bug)
            if vadEndpointingActive && !currentTranscription.isEmpty {
                handleVADResult(isSpeech: true)
            }
        }

        if result.isFinal {
            // Final result for this audio range - ACCUMULATE to previous segments
            // Each final result covers a specific audio range; multiple finals = multiple segments
            let filteredText = filterWakeWordByTiming(result)

            if !filteredText.isEmpty {
                if !self.accumulatedText.isEmpty {
                    // Append new segment to accumulated text
                    self.accumulatedText += " " + filteredText
                } else {
                    self.accumulatedText = filteredText
                }
            }

            // Display accumulated text (all finalized segments so far)
            self.transcription = self.accumulatedText
            self.lastSegment = ""  // Clear volatile segment tracker
            AppLogger.verbose("🎤 Final segment: \"\(filteredText)\" → Accumulated: \"\(self.accumulatedText)\"")

            // If processing, finalize immediately
            if self.isProcessing {
                self.finalizeSpeech()
                return
            }
        } else {
            // Volatile (partial) result - show accumulated + current volatile segment
            // Volatile results update repeatedly for the SAME audio range until finalized
            let filteredText = filterWakeWordByTiming(result)
            self.lastSegment = filteredText  // Track current volatile segment

            // Display: accumulated finals + current volatile
            if !self.accumulatedText.isEmpty && !filteredText.isEmpty {
                self.transcription = self.accumulatedText + " " + filteredText
            } else if !filteredText.isEmpty {
                self.transcription = filteredText
            } else {
                self.transcription = self.accumulatedText
            }
        }
    }

    /// Filter wake word by word timestamps (iOS 26)
    /// Uses model latency to calculate wake word end position in pre-roll audio
    private func filterWakeWordByTiming(_ result: SpeechTranscriber.Result) -> String {
        // Only apply filtering in wake word mode
        guard recordingState == .recordingWake else {
            return String(result.text.characters)
        }

        // Model-latency-based wake word end calculation:
        //
        // OpenWakeWord's hey_mister model uses embeddingWindowSize=11 embeddings,
        // each covering 80ms of audio. The model fires after seeing 11 embeddings,
        // so there's a fixed detection latency of: 11 × 80ms = 880ms = 0.88s
        //
        // When the model fires, the wake word ENDED approximately 0.88s ago.
        // In the pre-roll audio (1.5s), the wake word end is at:
        //   preRollDuration - modelLatency = 1.5s - 0.88s ≈ 0.62s
        //
        // SpeechTranscriber timestamps are relative to audio start (T=0 = pre-roll start),
        // so words with timestamps < 0.62s are part of the wake word.
        //
        // Add safety buffer for timing variance and "Hey Mister" trailing audio.
        let modelLatencySeconds: Double = 0.88  // 11 embeddings × 80ms
        let safetyBufferSeconds: Double = 0.10  // Account for timing variance

        // Calculate wake word end position using actual pre-roll duration
        let preRollDurationSeconds = actualPreRollDuration > 0 ? actualPreRollDuration : 1.5
        let wakeWordEndInAudio = preRollDurationSeconds - modelLatencySeconds + safetyBufferSeconds

        // Log calculation details
        AppLogger.verbose("📍 Model-latency filter: preRoll=\(String(format: "%.2f", preRollDurationSeconds))s, modelLatency=\(modelLatencySeconds)s, threshold=\(String(format: "%.2f", wakeWordEndInAudio))s")

        // Filter words by timing using AttributedString runs
        // Each run contains text + audioTimeRange attribute
        var filteredWords: [String] = []
        var debugInfo: [(String, Double)] = []  // For logging

        for run in result.text.runs {
            if let timeRange = run.audioTimeRange {
                // Convert CMTime to seconds (relative to start of audio buffer)
                let startTime = CMTimeGetSeconds(timeRange.start)
                let wordText = String(result.text.characters[run.range]).trimmingCharacters(in: .whitespaces)

                // Skip empty tokens (whitespace-only runs)
                guard !wordText.isEmpty else { continue }

                debugInfo.append((wordText, startTime))

                if startTime >= wakeWordEndInAudio {
                    filteredWords.append(wordText)
                }
            }
        }

        // Log filtering details for debugging
        if !debugInfo.isEmpty {
            let timingInfo = debugInfo.map { "\($0.0)@\(String(format: "%.2f", $0.1))s" }.joined(separator: ", ")
            AppLogger.standard("🕐 Word timestamps: [\(timingInfo)]")
            AppLogger.standard("🕐 Filter threshold: \(String(format: "%.2f", wakeWordEndInAudio))s (model-latency based)")
        }

        // Join filtered words
        let filteredText = filteredWords.joined(separator: " ")

        // Capitalize first letter
        guard !filteredText.isEmpty else {
            AppLogger.standard("🕐 All words filtered out (all before \(String(format: "%.2f", wakeWordEndInAudio))s)")
            return ""
        }
        return filteredText.prefix(1).uppercased() + filteredText.dropFirst()
    }

    /// Handle wake word detection
    /// NOTE: Sample positions (wakeWordSampleIndex, ringBufferSampleCountAtWake) are already
    /// stored by onWakeEvent callback which fires BEFORE this onWake callback
    @MainActor
    private func handleWakeDetected() {
        // CRITICAL: Set recordingState FIRST to block duplicate wake detections
        // Race condition: Multiple wake detections can happen in quick succession
        // @MainActor ensures this check+set is atomic on the main thread
        guard recordingState == .idle else {
            AppLogger.standard("🎤 Wake word ignored: already recording via \(recordingState)")
            return
        }

        // Immediately transition to recordingWake to block duplicate detections
        recordingState = .recordingWake

        // Block if TTS is speaking (prevent feedback loop)
        guard !isTTSSpeaking else {
            AppLogger.verbose("🎤 Wake word ignored: TTS is speaking")
            recordingState = .idle  // Restore state since we're aborting
            isProcessingWakeWord = false  // Allow next wake word attempt
            return
        }

        // Refractory period: ignore wake within 1.1s of previous
        let now = Date().timeIntervalSince1970
        if now - lastWakeTime < 1.1 {
            AppLogger.verbose("🎤 Wake word ignored: refractory period (\(Int((now - lastWakeTime) * 1000))ms since last)")
            recordingState = .idle  // Restore state since we're aborting
            isProcessingWakeWord = false  // Allow next wake word attempt
            return
        }
        lastWakeTime = now

        // Sample positions for timestamp alignment were already stored by onWakeEvent callback
        AppLogger.verbose("📍 Wake word sample positions - OWW: \(wakeWordSampleIndex), RingBuffer: \(ringBufferSampleCountAtWake)")

        // Restore screen brightness when wake word detected
        restoreScreen()
        resetDimTimer()  // Restart the 30-second dim countdown

        // Play wake word chime (non-blocking)
        Task { @MainActor in
            let feedbackService = WakeWordFeedbackService()
            feedbackService.playWakeWordChime()
        }

        AppLogger.standard("🎯 Wake word detected!")
        vadEndpointingActive = true
        lastSpeechTime = now
        wakeWordDetectedTime = now  // Track when wake word fired for gate period

        // Start SpeechDetector endpointing (iOS 26)
        startSpeechDetectorEndpointing()

        // Trigger recording (will feed 1.5s pre-roll)
        startRecording()

        // NOTE: isProcessingWakeWord stays true until resetToIdle() is called
        // This prevents duplicate wake word triggers during the entire AI processing cycle
        // The flag will be reset by resetToIdle() after AI response is complete
    }

    /// Strip wake word phrases from transcription and capitalize first letter
    /// Only applies to wake word mode; PTT mode passes through unchanged
    private func stripWakeWord(_ text: String) -> String {
        guard recordingState == .recordingWake else {
            // Only strip wake word in wake word mode, not PTT
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }

        // Common STT variations of "Hey Mister" observed in production
        // Ordered by frequency (most common first for performance)
        let wakeWordPrefixes = [
            "hey mister",
            "hey mr",
            "hey mr.",
            "hey mr ",
            "a mister",      // Common misrecognition
            "hay mister",    // Common misrecognition
            "hay mr",
            "hey misser",    // Variant pronunciation
        ]

        var result = trimmed
        let lowercasedResult = result.lowercased()

        // Find and remove wake word prefix
        for prefix in wakeWordPrefixes {
            if lowercasedResult.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }

        // Trim any leftover whitespace and punctuation at the start
        result = result.trimmingCharacters(in: .whitespaces)

        // Remove leading punctuation (commas, periods) that may follow wake word
        while !result.isEmpty && result.first?.isPunctuation == true {
            result = String(result.dropFirst())
        }

        result = result.trimmingCharacters(in: .whitespaces)

        // Capitalize first letter of the command
        if !result.isEmpty {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - Screen Management (Wake Word Mode)

    /// Start the dim timer - screen will dim after 30 seconds of inactivity
    private func startDimTimer() {
        dimTimer?.invalidate()
        dimTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dimScreen()
            }
        }
    }

    /// Reset the dim timer - restart the 30 second countdown
    private func resetDimTimer() {
        startDimTimer()
        // If screen was dimmed, restore it on activity
        if isDimmed {
            restoreScreen()
        }
    }

    /// Dim the screen to 20% brightness
    private func dimScreen() {
        #if os(iOS)
        guard !isDimmed else { return }
        UIScreen.main.brightness = 0.2
        isDimmed = true
        AppLogger.verbose("🌙 Screen dimmed to 20% (wake word idle)")
        #endif
    }

    /// Restore screen to original brightness
    private func restoreScreen() {
        #if os(iOS)
        guard isDimmed else { return }
        UIScreen.main.brightness = originalBrightness
        isDimmed = false
        AppLogger.verbose("☀️ Screen brightness restored (wake word active)")
        #endif
    }

    private func handleMissingSiriAssets() {
        AppLogger.connection("⚠️ Siri & Dictation required on this device")
        requiresSiriEnablement = true

        finalizationTimer?.invalidate()
        finalizationTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechCompletionHandler = nil
        isRecording = false
        isProcessing = false
    }
}

// MARK: - Dynamic Locale Support
extension SpeechService {
    private func configureLocaleObservation() {
#if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateSpeechRecognizerLocale()
            }
        }
#endif
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateSpeechRecognizerLocale()
            }
        }
    }

    private func updateSpeechRecognizerLocale() {
        let identifiers = preferredSpeechLanguageIdentifiers()
        for identifier in identifiers {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)), recognizer.isAvailable {
                if speechRecognizer?.locale.identifier != identifier {
                    AppLogger.verbose("🎙️ Updated speech recognizer locale: \(identifier)")
                }
                speechRecognizer = recognizer
                return
            }
        }

        if speechRecognizer == nil {
            AppLogger.connection("No supported speech recognizer locales found; defaulting to en-US")
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
    }

    private func preferredSpeechLanguageIdentifiers() -> [String] {
        var identifiers: [String] = []
#if os(iOS)
        let activeModeLanguages = UITextInputMode.activeInputModes.compactMap { $0.primaryLanguage }
        identifiers.append(contentsOf: activeModeLanguages)
#endif
        identifiers.append(contentsOf: Locale.preferredLanguages)
        identifiers.append(Locale.current.identifier)
        identifiers.append("en-US")

        var seen: Set<String> = []
        return identifiers.filter { identifier in
            if seen.contains(identifier) { return false }
            seen.insert(identifier)
            return true
        }
    }
}

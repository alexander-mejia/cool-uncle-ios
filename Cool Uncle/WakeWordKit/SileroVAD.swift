//
//  SileroVAD.swift
//  WakeWordKit
//
//  Silero Voice Activity Detection implementation using FluidAudio.
//  Uses the real Silero VAD model for production-quality speech detection.
//
//  📍 INTEGRATION NOTE: This implementation uses FluidAudio's production-ready VAD.
//  License: FluidAudio (Apache 2.0), Silero VAD (MIT) - both commercially friendly.
//

import Foundation
import AVFoundation
import os.log
import FluidAudio

/// Silero VAD implementation using FluidAudio's real Silero model
///
/// This uses the production Silero VAD deep learning model for accurate speech detection.
/// Optimized for 16kHz audio, processes in 4096-sample windows (~256ms).
///
public class SileroVAD: VoiceActivityDetector {

    // MARK: - Public Properties

    public var isSpeech: Bool {
        return lastProbability >= WakeWordConstants.vadSpeechThreshold
    }

    public private(set) var lastProbability: Float = 0.0

    /// Latency in milliseconds between audio capture and VAD processing completion
    public private(set) var processingLatencyMs: Double = 0.0

    // MARK: - Private Properties

    private var silenceStartTime: CFAbsoluteTime?
    private var speechStartTime: CFAbsoluteTime?
    private let windowSize: Int
    private var audioBuffer: [Float] = []

    /// Serial queue for VAD processing - ensures sequential window processing and thread-safe state management
    /// Session 7 Fix: Prevents parallel processing that corrupts Silero VAD's internal state
    private let vadQueue = DispatchQueue(label: "com.wakeword.sileroVAD", qos: .userInteractive)

    // FluidAudio VAD manager (real Silero model)
    private var vadManager: VadManager?
    private var streamState: VadStreamState?
    private var isInitialized: Bool = false

    // MARK: - VAD Smoothing State (Session 6)

    /// Hangover/Hold: Frames remaining to keep VAD active after speech drops
    private var vadHoldFramesRemaining: Int = 0

    /// Hysteresis: Current VAD state (prevents flapping at threshold boundary)
    private var vadActiveState: Bool = false

    /// Max-Duration Safety: Time when current speech segment started
    private var currentSpeechStartTime: CFAbsoluteTime?

    // MARK: - Initialization

    /// Initialize Silero VAD with real Silero model via FluidAudio
    /// - Parameter windowSize: Window size in samples (default: 4096 ≈ 256ms @ 16kHz)
    public init(windowSize: Int = WakeWordConstants.vadWindowSizeSamples) {
        self.windowSize = windowSize
        os_log("SileroVAD: Initializing with real Silero model via FluidAudio...")

        // Initialize async in background (VAD model loading doesn't block)
        Task {
            await initializeVAD()
        }
    }

    /// Async initialization of VAD manager and model
    private func initializeVAD() async {
        do {
            // Create VAD manager with default Silero model
            let manager = try await VadManager()
            vadManager = manager
            // makeStreamState() is actor-isolated, must await
            streamState = await manager.makeStreamState()
            isInitialized = true
            os_log("✅ SileroVAD: Real Silero model loaded successfully")
        } catch {
            os_log("❌ SileroVAD: Failed to load Silero model: %{public}@", error.localizedDescription)
            os_log("   Falling back to energy-based VAD (lower accuracy)")
            isInitialized = false
        }
    }

    // MARK: - VoiceActivityDetector Protocol

    /// Process audio samples and return speech probability using real Silero model
    /// - Parameter samples: Float32 audio samples (16kHz expected)
    /// - Returns: Speech probability (0.0 = silence, 1.0 = speech)
    ///
    /// Session 7 Fix: Uses serial queue to ensure sequential processing and prevent state corruption
    public func process(samples: [Float]) -> Float {
        let processingStartTime = CFAbsoluteTimeGetCurrent()

        // Process on serial queue to ensure thread safety and sequential execution
        return vadQueue.sync {
            // Accumulate samples
            audioBuffer.append(contentsOf: samples)

            // Process ALL available windows sequentially to stay in sync with real-time audio
            // Each window MUST complete before the next starts to maintain Silero VAD state continuity
            var lastResult = lastProbability

            while audioBuffer.count >= windowSize {
                // Extract window
                let window = Array(audioBuffer.prefix(windowSize))
                audioBuffer.removeFirst(windowSize)

                // Process this window (blocks until complete, uses updated state from previous window)
                lastResult = processWindowOnQueue(window)
            }

            // Calculate latency
            let processingEndTime = CFAbsoluteTimeGetCurrent()
            self.processingLatencyMs = (processingEndTime - processingStartTime) * 1000.0

            return lastResult
        }
    }

    /// Process a single 4096-sample window through Silero VAD on the serial queue
    /// CRITICAL: This must only be called from vadQueue to ensure thread safety
    /// Session 7 Fix: Uses self.streamState (not captured state) to maintain continuity across windows
    private func processWindowOnQueue(_ window: [Float]) -> Float {
        // MUST be called from vadQueue!
        dispatchPrecondition(condition: .onQueue(vadQueue))

        if window.count != windowSize {
            os_log("⚠️ Silero VAD: expected %d samples, received %d", windowSize, window.count)
        }

        // Process window with real Silero VAD or fallback
        if isInitialized, let manager = vadManager {
            // Use real Silero VAD model
            // We need to block and wait for the async call to complete
            let group = DispatchGroup()
            var resultProb: Float = lastProbability
            var processingError: Error?

            #if DEBUG
            // Log audio characteristics before processing (only occasionally)
            // Session 7: Increased logging frequency temporarily to verify AGC consistency
            if Int.random(in: 0..<10) == 0 {  // Log ~10% of windows (was 2% - revert after testing)
                let rms = sqrtf(window.reduce(0) { $0 + $1 * $1 } / Float(window.count))
                let maxSample = window.max() ?? 0
                let minSample = window.min() ?? 0
                os_log("📊 VAD Input: samples=%d, RMS=%.4f, range=[%.4f, %.4f]",
                       window.count, rms, minSample, maxSample)
            }
            #endif

            group.enter()
            Task {
                do {
                    // CRITICAL FIX: Use self.streamState (current) not a captured copy!
                    // This ensures each window builds on the state from the previous window
                    guard let currentState = self.streamState else {
                        throw NSError(domain: "SileroVAD", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream state is nil"])
                    }

                    let result = try await manager.processStreamingChunk(
                        window,
                        state: currentState,  // ← Fixed: uses current state, not captured
                        config: .default
                    )

                    // Update state for next chunk (VadStreamResult contains updated state)
                    self.streamState = result.state

                    // Get raw probability from Silero VAD
                    let rawProb = result.probability

                    // Apply smoothing pipeline (Session 6 - all enabled post-processing)
                    let smoothedProb = self.applySmoothingPipeline(rawProbability: rawProb)

                    // Update probability with smoothed value
                    resultProb = smoothedProb
                    self.lastProbability = smoothedProb
                    self.updateSilenceTracking(isSpeech: smoothedProb >= WakeWordConstants.vadSpeechThreshold)

                    #if DEBUG
                    // VAD logging disabled - uncomment if debugging VAD issues
                    // VAD has been stable, and logging creates too much noise in console
                    // if rawProb > 0.5 {
                    //     os_log("🔊 Silero VAD: raw=%.2f → smoothed=%.2f (SPEECH) latency=%.1fms",
                    //            rawProb, smoothedProb, self.processingLatencyMs)
                    // }
                    #endif
                } catch {
                    processingError = error
                }
                group.leave()
            }

            // Wait for processing to complete (with timeout)
            let timeoutResult = group.wait(timeout: .now() + .milliseconds(100))

            if timeoutResult == .timedOut {
                os_log("⚠️ SileroVAD: Processing timeout, using fallback")
                let fallbackProb = energyBasedVAD(samples: window)
                lastProbability = fallbackProb
                updateSilenceTracking(isSpeech: fallbackProb >= WakeWordConstants.vadSpeechThreshold)
                return fallbackProb
            }

            if let error = processingError {
                os_log("⚠️ SileroVAD: Processing error: %{public}@", error.localizedDescription)
                let fallbackProb = energyBasedVAD(samples: window)
                lastProbability = fallbackProb
                updateSilenceTracking(isSpeech: fallbackProb >= WakeWordConstants.vadSpeechThreshold)
                return fallbackProb
            }

            // Success - return the result from Silero VAD
            return resultProb
        } else {
            // Fallback: Energy-based VAD (while Silero loads or if failed)
            let probability = energyBasedVAD(samples: window)
            lastProbability = probability
            updateSilenceTracking(isSpeech: probability >= WakeWordConstants.vadSpeechThreshold)
            return probability
        }
    }

    // MARK: - VAD Smoothing Pipeline (Session 6)

    /// Apply all enabled smoothing techniques to raw VAD probability
    /// This is the "production VAD state machine" that implements temporal smoothing
    ///
    /// Pipeline: Raw Silero → Hysteresis → Hangover → Final
    ///
    /// - Parameter rawProbability: Raw probability from Silero VAD (0.0-1.0)
    /// - Returns: Smoothed probability after all post-processing
    private func applySmoothingPipeline(rawProbability: Float) -> Float {
        var prob = rawProbability

        // STEP 1: Hysteresis (dual thresholds for activation vs deactivation)
        if WakeWordConstants.useHysteresis {
            prob = applyHysteresis(probability: prob)
        }

        // STEP 2: Hangover/Hold (keep VAD active after speech drops)
        if WakeWordConstants.useVADHangover {
            prob = applyHangover(probability: prob)
        }

        // STEP 3: Max-Duration Safety (timeout for runaway speech)
        prob = applyMaxDurationSafety(probability: prob)

        return prob
    }

    /// TECHNIQUE 1: Hysteresis (Dual Thresholds)
    /// Different thresholds for turning ON vs turning OFF
    /// Research: "Hysteresis rules prevent rapid flickering by using different toggles"
    ///
    /// Example with thresholds 0.35 (ON) / 0.20 (OFF):
    ///   State: INACTIVE, prob=0.36 → Activate (crossed 0.35) → State: ACTIVE
    ///   State: ACTIVE, prob=0.25 → Stay active (above 0.20 deactivation threshold)
    ///   State: ACTIVE, prob=0.18 → Deactivate (dropped below 0.20) → State: INACTIVE
    private func applyHysteresis(probability: Float) -> Float {
        if vadActiveState {
            // Currently active - need to drop below LOWER threshold to deactivate
            if probability < WakeWordConstants.vadDeactivationThreshold {
                vadActiveState = false
                return probability  // Return actual low probability
            } else {
                // Stay active
                return probability
            }
        } else {
            // Currently inactive - need to exceed HIGHER threshold to activate
            if probability > WakeWordConstants.vadActivationThreshold {
                vadActiveState = true
                return probability  // Return actual high probability
            } else {
                // Stay inactive
                return probability
            }
        }
    }

    /// TECHNIQUE 2: Hangover/Hold Time
    /// Keep VAD active for N frames after speech drops to handle micro-pauses
    /// Research: "Hangover schemes keep speech flag active for extra frames so brief pauses don't chop syllables"
    ///
    /// CRITICAL: Must use deactivation threshold (0.25), NOT speech threshold (0.30)!
    /// Why: Hysteresis keeps VAD active between 0.25-0.30 (dead zone)
    /// Hangover should only activate when prob drops BELOW 0.25 (actual silence)
    ///
    /// Example with 1-frame hold (≈256ms at current configuration):
    ///   Frame 100: prob=0.95 (speech) → holdRemaining=1, return 0.95
    ///   Frame 101: prob=0.20 (below deactivation) → holdRemaining=1, return 0.30 (artificial speech)
    ///   Frame 102: prob=0.03 (actual silence) → holdRemaining=0, return 0.03 (hold expired)
    private func applyHangover(probability: Float) -> Float {
        // Use deactivation threshold (0.25) not speech threshold (0.30)!
        // This is critical for proper interaction with hysteresis
        let isSpeech = probability >= WakeWordConstants.vadDeactivationThreshold

        if isSpeech {
            // Speech detected (or in dead zone) - reset hold timer
            vadHoldFramesRemaining = WakeWordConstants.vadHangoverFrames
            return probability
        } else {
            // Below deactivation threshold - check if we're still in hold period
            if vadHoldFramesRemaining > 0 {
                vadHoldFramesRemaining -= 1
                // Return artificial "speech" probability during hold
                // Use activation threshold (0.30) to keep VAD active
                return WakeWordConstants.vadActivationThreshold
            } else {
                // Hold period expired - return actual silence probability
                return probability
            }
        }
    }

    /// TECHNIQUE 3: Maximum Speech Duration Safety
    /// Timeout after N seconds of continuous speech to prevent runaway VAD
    /// Handles case where user walks away mid-utterance or background noise persists
    private func applyMaxDurationSafety(probability: Float) -> Float {
        let isSpeech = probability >= WakeWordConstants.vadSpeechThreshold
        let now = CFAbsoluteTimeGetCurrent()

        if isSpeech {
            // Track speech start time
            if currentSpeechStartTime == nil {
                currentSpeechStartTime = now
            }

            // Check if speech has exceeded maximum duration
            if let startTime = currentSpeechStartTime {
                let durationMs = (now - startTime) * 1000.0
                if durationMs > WakeWordConstants.vadMaxSpeechDurationMs {
                    #if DEBUG
                    // Force silence after timeout
                    os_log("⏱️ VAD max duration exceeded (%.0f ms), forcing silence", durationMs)
                    #endif
                    currentSpeechStartTime = nil
                    return 0.0
                }
            }

            return probability
        } else {
            // Reset speech start time on silence
            currentSpeechStartTime = nil
            return probability
        }
    }

    /// Check if we've been silent for the specified duration
    /// - Parameter durationMs: Minimum silence duration in milliseconds
    /// - Returns: True if silence duration exceeds threshold
    public func isSilent(durationMs: Double) -> Bool {
        guard let silenceStart = silenceStartTime else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        let silenceDuration = (now - silenceStart) * 1000.0 // Convert to ms

        return silenceDuration >= durationMs
    }

    /// Reset internal state
    public func reset() {
        audioBuffer.removeAll()
        lastProbability = 0.0
        silenceStartTime = nil
        speechStartTime = nil

        // Reset smoothing state (Session 6)
        vadHoldFramesRemaining = 0
        vadActiveState = false
        currentSpeechStartTime = nil

        // Reset Silero VAD streaming state (makeStreamState() is actor-isolated)
        if isInitialized, let manager = vadManager {
            Task {
                streamState = await manager.makeStreamState()
            }
        }
    }

    // MARK: - Private Methods

    /// Fallback energy-based VAD (used when FluidAudio is not available)
    /// - Parameter samples: Audio samples
    /// - Returns: Estimated speech probability
    private func energyBasedVAD(samples: [Float]) -> Float {
        // Calculate RMS energy
        var sum: Float = 0.0
        var maxAbs: Float = 0.0

        for sample in samples {
            sum += sample * sample
            let abs = Swift.abs(sample)
            if abs > maxAbs { maxAbs = abs }
        }

        let rms = sqrtf(sum / Float(max(1, samples.count)))
        let db = 20.0 * log10f(rms + 1e-6)

        // Map dBFS to probability (tuned for wake word detection)
        // More sensitive than UI meter - needs to catch quiet speech
        // -70 dBFS → 0.0, -50 dBFS → 0.5, -30 dBFS → 1.0
        let centerThreshold: Float = -50.0  // Middle point (50% probability)
        let range: Float = 40.0  // Total range for 0-100%

        let normalized = (db - (centerThreshold - range/2)) / range
        let probability = max(0.0, min(1.0, normalized))

        return probability
    }

    /// Update silence/speech tracking
    /// - Parameter isSpeech: Whether current frame is speech
    private func updateSilenceTracking(isSpeech: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        if isSpeech {
            // Speech detected
            if speechStartTime == nil {
                speechStartTime = now
            }
            silenceStartTime = nil
        } else {
            // Silence detected
            if silenceStartTime == nil {
                silenceStartTime = now
            }
            speechStartTime = nil
        }
    }
}

// MARK: - Real Silero VAD Integration

/// 📍 INTEGRATION COMPLETE: This implementation now uses FluidAudio's real Silero VAD model!
///
/// 1. Add FluidAudio dependency to Package.swift:
///    ```swift
///    dependencies: [
///        .package(url: "https://github.com/FluidInference/FluidAudio", from: "1.0.0")
///    ]
///    ```
///
/// 2. Import FluidAudio in this file:
///    ```swift
///    import FluidAudio
///    ```
///
/// 3. Replace the fallback VAD with FluidAudio:
///    ```swift
///    private var vadManager: VadManager?
///
///    public init() async throws {
///        self.vadManager = try await VadManager()
///        self.streamState = await vadManager.makeStreamState()
///    }
///
///    public func process(samples: [Float]) -> Float {
///        let result = try await vadManager.processStreamingChunk(
///            samples,
///            state: streamState,
///            config: .default
///        )
///        return result.probability
///    }
///    ```
///
/// 4. Benefits of FluidAudio:
///    - Production-quality Silero VAD
///    - Optimized CoreML implementation
///    - Uses Apple Neural Engine
///    - Better accuracy than energy-based VAD
///    - Maintained and tested
///
/// **For now, this implementation uses a simple energy-based fallback VAD**
/// that's sufficient for testing but should be replaced with FluidAudio for production.
///
/// Alternative: You can also use the CoreML model directly:
/// - Download from: https://huggingface.co/FluidInference/silero-vad-coreml
/// - Add to Xcode project
/// - Load with `CoreMLModel` API
/// - Process 4096-sample chunks

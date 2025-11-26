//
//  Constants.swift
//  WakeWordKit
//
//  Centralized configuration for wake word detection, VAD, and audio processing.
//  Tune these values based on your environment and performance requirements.
//

import Foundation

/// All tunable parameters for wake word detection and VAD
public struct WakeWordConstants {

    // MARK: - Audio Configuration

    /// Sample rate for all audio processing (OpenWakeWord and Silero VAD expect 16 kHz)
    public static let sampleRate: Double = 16_000

    /// Frame duration in milliseconds (OpenWakeWord recommendation: 80ms minimum)
    public static let frameSizeMs: Int = 80

    /// Frame size in samples at 16 kHz (80ms = 1280 samples)
    public static let frameSizeSamples: Int = Int(sampleRate * Double(frameSizeMs) / 1000.0)

    /// Scale factor to convert normalized [-1, 1] Float audio back to 16-bit PCM magnitude
    /// OpenWakeWord ONNX models were trained on raw Int16 PCM values, so we need to scale
    /// Float samples before running the mel-spectrogram model.
    public static let pcm16AmplitudeScale: Float = 32768.0

    /// Preferred IO buffer duration for AVAudioSession (lower = lower latency)
    /// 10ms for low-latency mode (trades battery for responsiveness)
    public static let ioBufferDuration: TimeInterval = 0.01 // 10ms

    // MARK: - Wake Word Detection

    /// **V3 Model Configuration (hey_mister_V3_epoch_60.onnx)**
    /// • Input shape: [1, 11, 96] (11 embeddings × 96 dimensions)
    /// • Clip size: ~0.88s (11 embeddings × 80ms)
    /// • Frame timing: 80ms per mel frame → 16ms per embedding
    /// • Detection latency: ~0.88s (must accumulate full window before detection)
    ///
    /// **Timing Budget:**
    /// • Total detection window: 0.88 seconds
    /// • Short-window (5 embeddings): 0.40s for wake word isolation
    /// • Remaining context (6 embeddings): 0.48s for post-wake-word capture
    /// • STT pre-roll: 1.0s to capture fast-spoken commands
    /// • VAD redemption: 750ms (tolerates ONNX "Invalid frame" errors during speech)
    /// • Refractory period: 1.1s cooldown between detections
    ///
    /// **Note on Detection Latency:**
    /// The ~0.88s delay between saying "Hey Mister" and detection triggering is
    /// architectural - the model needs a full 11-embedding window. To reduce this,
    /// you would need to retrain with fewer embeddings (e.g., 7 embeddings = 0.56s).
    ///
    /// All timing parameters below are tuned for this 0.88s model window.
    /// If you switch models, you MUST adjust these proportionally!

    /// Wake word score threshold (0.0-1.0). Higher = fewer false accepts, more misses.
    /// CRITICAL: Model scores very low (0.05-0.2 for valid utterances)
    /// History:
    /// - 0.15: Initial value matching score distribution
    /// - 0.18: Noise floor analysis (borderline cases)
    /// - 0.25: Reduced false positives while maintaining detection (Session 4 tuning)
    /// Refractory period (1.1s) prevents false re-triggers from score decay
    public static var kwsThreshold: Float {
        WakeWordRuntimeConfig.current.kwsThreshold ?? 0.25
    }

    /// Optional secondary wake inference on a shorter context (in embeddings).
    /// 0 disables the extra pass. Tuned for V3 model (11 embeddings total):
    /// - 5 embeddings = 0.40s captures wake word
    /// - Remaining 6 embeddings = 0.48s captures fast-spoken commands
    /// (Previously 7 for V2 16-embedding model, but that left only 0.32s for commands on V3)
    /// V7 MODEL: Disabled - V7 has 8 embeddings, window already matches wake word duration
    public static var kwsShortWindowEmbeddings: Int {
        WakeWordRuntimeConfig.current.kwsShortWindowEmbeddings ?? 0  // Was: 5 (disabled for V7)
    }
    /// Minimum base model score required before short-window boost is considered.
    /// Prevents arbitrary speech from triggering the shortened inference path.
    /// Lowered to 0.10 for V3 model (shorter 11-embedding window may produce lower base scores)
    public static var kwsShortWindowMinBaseScore: Float {
        WakeWordRuntimeConfig.current.kwsShortWindowMinBaseScore ?? 0.10
    }
    /// Length of buffered audio to retain (seconds) for STT pre-roll.
    public static let audioBufferDurationSec: Double = 5.0
    /// Amount of audio preceding the wake word to feed into STT when a wake fires.
    /// Increased to 1.0s for V3 model to ensure fast-spoken commands are fully captured
    public static let sttPreRollSec: Double = 1.0

    /// EMA (Exponential Moving Average) alpha for score smoothing
    /// score = (1-alpha)*prevScore + alpha*currentScore
    /// Higher alpha = more responsive to current frame
    /// V7 MODEL: Increased to 0.95 for faster response to score peaks during immediate commands
    public static let kwsEMAAlpha: Float = 0.95  // Was: 0.8

    /// How many consecutive frames with VAD=true required before accepting wake word
    /// Session 6: Set to 0 to make VAD advisory rather than required
    /// The wake word model provides excellent discrimination (scores 0.3-0.8+)
    /// VAD micro-drops during utterance shouldn't block valid detections
    /// Lowered from 1 to 0 to eliminate "near miss" false negatives
    public static var vadRequiredFrames: Int {
        WakeWordRuntimeConfig.current.vadRequiredFrames ?? 0
    }

    /// Refractory period after wake detection (seconds) - prevents double-firing
    /// Tuned for V3 model (0.88s window): 1.1s provides adequate cooldown
    /// without being overly conservative for the shorter detection window
    public static let refractoryPeriodSec: Double = 1.1

    // MARK: - Voice Activity Detection (VAD)

    /// Silero VAD probability threshold (0.0-1.0)
    /// Above this = speech, below = silence
    /// FluidAudio Silero VAD returns 0.5-0.95 during speech, 0.00-0.05 during silence
    ///
    /// NOTE: When hysteresis is enabled, this is the ACTIVATION threshold (harder to turn ON)
    /// Deactivation uses vadDeactivationThreshold (easier to stay ON once active)
    public static let vadSpeechThreshold: Float = 0.3

    /// For VAD window aggregation: how many sub-windows must be speech
    /// to consider the full frame as "speech"
    /// Example: 3 out of 4 windows (20ms each) = 0.75 confidence
    public static let vadSpeechVotesRequired: Int = 3
    public static let vadTotalVotes: Int = 4

    /// Redemption-Based Endpointing (Session 6 - Based on ricky0123/vad)
    /// Uses FIXED redemption period - works for both short and long utterances!
    /// Research: https://github.com/ricky0123/vad
    ///
    /// How it works:
    /// 1. When speaking, if VAD drops below negativeSpeechThreshold → start redemption timer
    /// 2. If VAD goes back above positiveSpeechThreshold before timer expires → RESET timer (keep listening)
    /// 3. If timer expires (redemptionMs of continuous low VAD) → END speech segment
    ///
    /// This is MUCH better than adaptive timeout because:
    /// - Constant redemption period works for ALL utterance lengths
    /// - Natural pauses reset the timer automatically
    /// - No need to predict if user is "wrapping up"

    /// Redemption period (ms) - How long VAD must stay below negativeSpeechThreshold to end
    /// Set to 750ms to tolerate ONNX Runtime "Invalid frame dimension" errors that cause
    /// temporary VAD dropouts during speech. Without this buffer, the redemption timer
    /// expires prematurely when ONNX errors prevent VAD from processing frames.
    /// See DEVELOPMENT_STATUS.md "Invalid frame dimension" section for details.
    public static let vadRedemptionMs: Double = 750

    /// Minimum speech duration (ms) - Reject segments shorter than this (prevents false positives)
    /// Default from ricky0123/vad: 400ms
    public static let vadMinSpeechMs: Double = 400  // 400ms

    /// VAD window size for Silero (FluidAudio CoreML build expects 4096 samples ≈ 256ms @ 16kHz)
    public static let vadWindowSizeSamples: Int = 4096

    /// Window duration derived from the VAD hop size
    public static let vadWindowDurationMs: Double = (Double(vadWindowSizeSamples) / sampleRate) * 1000.0

    // MARK: - VAD Smoothing & Post-Processing (Session 6)

    /// 🎛️ FEATURE FLAGS: Enable/disable each smoothing technique for A/B testing

    /// Use AVAudioEngine voice processing (AGC + noise suppression + echo cancellation)
    /// This applies processing at the engine level before the audio tap.
    /// Can be overridden at runtime via WakeWordRuntimeConfig for A/B testing
    public static var useVoiceProcessing: Bool {
        // Check runtime override first, fall back to default
        if let override = WakeWordRuntimeConfig.current.useVoiceProcessing {
            return override
        }
        return false  // A/B TEST: Switched to Option C (.videoRecording mode) - was: true
    }

    /// Use .videoRecording audio mode for mode-level voice processing
    /// 🎯 A/B TESTING: Compare engine-level (useVoiceProcessing) vs mode-level processing
    /// When true: Uses .videoRecording mode (AGC + noise suppression at session level)
    /// When false: Uses .default mode (raw audio, relies on useVoiceProcessing)
    /// Can be overridden at runtime via WakeWordRuntimeConfig for A/B testing
    public static var useVideoRecordingMode: Bool {
        if let override = WakeWordRuntimeConfig.current.useVideoRecordingMode {
            return override
        }
        return true  // A/B TEST: Switched to Option C (.videoRecording mode) - was: false
    }

    /// Use .measurement audio mode instead of .videoRecording
    /// 🎯 CPU OPTIMIZATION: .measurement saves 8-12% CPU by disabling voice processing
    /// ⚠️ TRADEOFF: No AGC, noise suppression, or echo cancellation
    /// Test this to see if wake word detection still works well without voice processing
    /// Can be overridden at runtime via WakeWordRuntimeConfig for A/B testing
    public static var useMeasurementMode: Bool {
        if let override = WakeWordRuntimeConfig.current.useMeasurementMode {
            return override
        }
        return false  // Default: disabled (use .videoRecording with voice processing)
    }
    public static let useVADHangover: Bool = true          // Hold VAD active after speech (prevents mid-word cutoff)
    public static let useHysteresis: Bool = true           // Dual thresholds (activation vs deactivation)

    /// Hangover/Hold Time: Keep VAD active for N frames after speech drops
    /// This prevents micro-pauses in speech from turning off VAD (e.g., pauses between words)
    /// Industry standard: 150-500ms
    /// With 4096-sample windows, this translates to ~256ms per frame
    /// Research: "Hangover schemes prevent cutting off speech segments prematurely"
    /// TUNED: 256ms hangover ≈ 1 frame at 256ms per frame
    public static let vadHangoverDurationMs: Double = 256
    public static var vadHangoverFrames: Int {
        max(1, Int(round(vadHangoverDurationMs / vadWindowDurationMs)))
    }

    /// Hysteresis: Different thresholds for activation vs deactivation
    /// Prevents rapid on/off flapping at threshold boundary
    /// Based on ricky0123/vad defaults:
    /// - positiveSpeechThreshold: 0.30 (activate / redemption reset)
    /// - negativeSpeechThreshold: 0.25 (must stay below for redemption period)
    /// Research: "Hysteresis rules prevent rapid flickering by using different toggles"
    ///
    /// Key insight: Frames between negative and positive thresholds are IGNORED
    /// This creates a "dead zone" that prevents flapping
    public static let vadActivationThreshold: Float = 0.30   // positiveSpeechThreshold (activate/redemption reset)
    public static let vadDeactivationThreshold: Float = 0.25 // negativeSpeechThreshold (start redemption timer)

    /// Max Speech Duration: Safety timeout for continuous speech
    /// Prevents infinite VAD activation if user walks away mid-utterance
    /// Standard: 15-30 seconds
    public static let vadMaxSpeechDurationMs: Double = 30_000  // 30 seconds

    /// Exponential Moving Average (EMA) for probability smoothing
    /// alpha = 0.3 = slow/smooth, alpha = 0.7 = fast/responsive
    /// Currently not used (median filter preferred), but available for tuning
    public static let vadEMAAlpha: Float = 0.3

    // MARK: - Performance & Debugging

    /// Enable/disable CoreML Execution Provider for ONNX Runtime
    /// (Set to false to test CPU-only performance)
    /// NOTE: The onnxruntime-swift-package-manager package includes CoreML EP support
    ///       If you get "Unknown provider" errors, you may need to switch to onnxruntime-mobile
    ///       See COREML_FIX.md for instructions
    public static let useCoreMLExecutionProvider: Bool = true

    /// Enable validation checks for NaN/Inf values in inference pipeline
    /// Set to false in production to avoid performance overhead
    /// Useful for debugging "Invalid frame dimension" errors
    #if DEBUG
    public static let enableInferenceValidation: Bool = true
    #else
    public static let enableInferenceValidation: Bool = false
    #endif

    /// Enable detailed frame-by-frame logging for debugging audio pipeline issues
    /// Logs PCM frame statistics every 50 frames and whenever NaN/Inf detected
    /// Set to false in production to reduce log spam
    /// Useful for debugging "Invalid frame dimension" ONNX errors
    #if DEBUG
    public static let enableDetailedFrameLogging: Bool = false  // Disabled by default (CPU optimization)
    #else
    public static let enableDetailedFrameLogging: Bool = false
    #endif

    /// CoreML compute units setting
    /// Options: "CPUOnly", "CPUAndGPU", "CPUAndNeuralEngine", "All"
    public static let coreMLComputeUnits: String = "CPUAndNeuralEngine"

    /// Enable model caching to avoid recompiling CoreML models on each launch
    public static let enableModelCaching: Bool = true

    /// Cache directory name (relative to app's Caches directory)
    public static let modelCacheDirectoryName: String = "coreml_model_cache"
}

/// 📍 INTEGRATION POINT: Adjust these constants to tune for your use case
///
/// Common tuning scenarios:
///
/// 1. **High false accept rate** (waking on background noise):
///    - Increase `kwsThreshold` to 0.55-0.60
///    - Increase `vadRequiredFrames` to 4-5
///    - Increase `vadSpeechThreshold` to 0.65-0.70
///
/// 2. **Missing wake words** (user has to repeat):
///    - Decrease `kwsThreshold` to 0.45-0.48
///    - Decrease `vadRequiredFrames` to 2
///    - Decrease `vadSpeechThreshold` to 0.5-0.55
///
/// 3. **High latency** (slow to respond):
///    - Decrease `vadRequiredFrames` to 2
///    - Decrease `frameSizeMs` to 40 (requires model retraining)
///    - Decrease `ioBufferDuration` to 0.01
///
/// 4. **High CPU usage**:
///    - Ensure `useCoreMLExecutionProvider = true`
///    - Check that models have static input shapes
///    - Increase `ioBufferDuration` to 0.04
///
/// 5. **Poor endpointing** (cuts off too early):
///    - Increase `vadSilenceHangMs` to 750-1000
///

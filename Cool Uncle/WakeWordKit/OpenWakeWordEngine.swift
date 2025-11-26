//
//  OpenWakeWordEngine.swift
//  WakeWordKit
//
//  OpenWakeWord implementation using ONNX Runtime with CoreML EP.
//  Implements VAD-gated wake word detection with EMA smoothing.
//

import Foundation
import AVFoundation
import os.log

/// Wake word detection metadata produced during offline testing.
public struct WakeDetectionEvent: Sendable {
    /// Final detection score (post smoothing / combination).
    public let score: Float
    /// Raw wake model score for the triggering frame.
    public let rawScore: Float
    /// EMA-smoothed score at detection time.
    public let emaScore: Float
    /// Number of VAD-active frames observed prior to detection.
    public let vadActiveFrames: Int
    /// Total audio samples processed (16 kHz) when detection fired.
    public let sampleIndex: Int
    /// Wake inference frame index (for debugging temporal pooling).
    public let frameIndex: Int
    /// Wall-clock timestamp when detection was emitted.
    public let timestamp: Date

    public init(
        score: Float,
        rawScore: Float,
        emaScore: Float,
        vadActiveFrames: Int,
        sampleIndex: Int,
        frameIndex: Int,
        timestamp: Date = Date()
    ) {
        self.score = score
        self.rawScore = rawScore
        self.emaScore = emaScore
        self.vadActiveFrames = vadActiveFrames
        self.sampleIndex = sampleIndex
        self.frameIndex = frameIndex
        self.timestamp = timestamp
    }

    /// Convenience access to the detection offset in milliseconds.
    public var timeOffsetMs: Double {
        (Double(sampleIndex) / WakeWordConstants.sampleRate) * 1000.0
    }
}

/// OpenWakeWord engine implementation
///
/// 📍 INTEGRATION POINT: This is the main wake word detection engine.
/// It processes 16kHz audio in 80ms frames (1280 samples) and triggers
/// the onWake callback when the wake word is detected.
///
public class OpenWakeWordEngine: WakeWordEngine {

    // MARK: - Public Properties

    public var onWake: (() -> Void)?
    public var onWakeEvent: (@Sendable (WakeDetectionEvent) -> Void)?
    public private(set) var currentScore: Float = 0.0
    public private(set) var latestRawScore: Float = 0.0
    public private(set) var vadProbability: Float = 0.0
    public private(set) var vadLatencyMs: Double = 0.0  // VAD processing latency
    public private(set) var maxScoreObserved: Float = 0.0
    public private(set) var maxRawScoreObserved: Float = 0.0
    public private(set) var isRunning: Bool = false
    public private(set) var detectionEvents: [WakeDetectionEvent] = []

    // MARK: - Private Properties

    private let modelPath: String
    private let melSpectrogramPath: String
    private let embeddingModelPath: String
    private var melSpectrogramSession: ONNXSession?
    private var embeddingSession: ONNXSession?
    private var wakeWordSession: ONNXSession?
    private let vad: SileroVAD
    private let ringBuffer: AudioRingBuffer
    private var resampler: Resampler?

    // Mel-spectrogram buffer (need 76 frames for embedding model)
    private var melBuffer: [Float] = []
    private let melWindowSize: Int = 76  // Number of mel frames needed
    private let melStepSize: Int = 8     // Sliding window step (in frames) - MUST match training!
    private let numMels: Int = 32        // Mel frequency bins
    private var embeddingBuffer: [Float] = []
    private var embeddingWindowSize: Int = 0   // Auto-detected from wake word model input shape
    private let embeddingStepSize: Int = 1     // Slide one embedding at a time (back to baseline)
    private let embeddingDimension: Int = 96   // Embedding feature size

    // Wake word detection state
    private var emaScore: Float = 0.0
    private var vadActiveFrames: Int = 0
    private var lastWakeTime: CFAbsoluteTime = 0
    private var totalSamplesProcessed: Int = 0

    // Performance tracking
    private var frameCount: Int = 0
    private var totalInferenceTime: CFAbsoluteTime = 0

    // Debug: Frame validation tracking
    private var totalFramesProcessed: Int = 0
    private var badFramesDetected: Int = 0
    private var nanValuesScrubbed: Int = 0
    private var frameMetadataBuffer: [(index: Int, rms: Float, max: Float, min: Float, hasNaN: Bool)] = []
    private let frameMetadataBufferSize: Int = 20

    // Thread safety
    private let processingQueue = DispatchQueue(label: "com.wakewordkit.openwakeword", qos: .userInitiated)

    // MARK: - Initialization

    /// Initialize OpenWakeWord engine
    /// - Parameters:
    ///   - modelPath: Path to wake word ONNX model file (.onnx)
    ///   - melSpectrogramPath: Path to mel-spectrogram preprocessing model (.onnx)
    ///   - embeddingModelPath: Path to embedding model (.onnx)
    public init(modelPath: String, melSpectrogramPath: String, embeddingModelPath: String) {
        self.modelPath = modelPath
        self.melSpectrogramPath = melSpectrogramPath
        self.embeddingModelPath = embeddingModelPath
        self.vad = SileroVAD()
        self.ringBuffer = AudioRingBuffer(
            frameSize: WakeWordConstants.frameSizeSamples,
            multiplier: 3
        )

        os_log("OpenWakeWordEngine: Initialized with wake word model: %{public}@", modelPath)
        os_log("OpenWakeWordEngine: Mel-spectrogram model: %{public}@", melSpectrogramPath)
        os_log("OpenWakeWordEngine: Embedding model: %{public}@", embeddingModelPath)
    }

    // MARK: - WakeWordEngine Protocol

    /// Start the engine
    public func start() throws {
        guard !isRunning else { return }

        // Load mel-spectrogram preprocessing model
        do {
            melSpectrogramSession = try ONNXSession(
                modelPath: melSpectrogramPath,
                useCoreML: WakeWordConstants.useCoreMLExecutionProvider
            )
        } catch {
            throw WakeWordError.modelLoadFailed("Mel-spectrogram model: \(error.localizedDescription)")
        }

        guard let melSession = melSpectrogramSession else {
            throw WakeWordError.modelLoadFailed("Failed to create mel-spectrogram session")
        }

        // Validate mel-spectrogram model expects [batch, samples] raw audio
        // Note: Shape may be dynamic ([-1, -1]) to support variable batch/sequence lengths
        let melInputShape = melSession.inputShape
        guard melInputShape.count == 2 else {
            throw WakeWordError.invalidModelShape(melInputShape.map { $0.intValue })
        }

        os_log("OpenWakeWordEngine: Mel-spectrogram model loaded, input shape: %{public}@ (dynamic shapes OK)", String(describing: melInputShape))

        // Load embedding model
        do {
            embeddingSession = try ONNXSession(
                modelPath: embeddingModelPath,
                useCoreML: WakeWordConstants.useCoreMLExecutionProvider
            )
        } catch {
            throw WakeWordError.modelLoadFailed("Embedding model: \(error.localizedDescription)")
        }

        guard let embSession = embeddingSession else {
            throw WakeWordError.modelLoadFailed("Failed to create embedding session")
        }

        // Validate embedding model (should accept mel features)
        let embInputShape = embSession.inputShape
        guard embInputShape.count >= 3 else {
            throw WakeWordError.invalidModelShape(embInputShape.map { $0.intValue })
        }

        os_log("OpenWakeWordEngine: Embedding model loaded, input shape: %{public}@ (dynamic shapes OK)", String(describing: embInputShape))

        // Load wake word model
        do {
            wakeWordSession = try ONNXSession(
                modelPath: modelPath,
                useCoreML: WakeWordConstants.useCoreMLExecutionProvider
            )
        } catch {
            throw WakeWordError.modelLoadFailed("Wake word model: \(error.localizedDescription)")
        }

        guard let kwsSession = wakeWordSession else {
            throw WakeWordError.modelLoadFailed("Failed to create wake word session")
        }

        // Validate wake word model expects [batch, embeddings, 96] features
        let kwsInputShape = kwsSession.inputShape
        guard kwsInputShape.count == 3 else {
            throw WakeWordError.invalidModelShape(kwsInputShape.map { $0.intValue })
        }

        // Auto-detect time dimension from model's input shape
        let modelTimeDimension = kwsInputShape[1].intValue
        guard modelTimeDimension > 0 && modelTimeDimension <= 32 else {
            throw WakeWordError.invalidModelShape(kwsInputShape.map { $0.intValue })
        }

        // Set embeddingWindowSize from model
        embeddingWindowSize = modelTimeDimension

        // Extract model filename for logging
        let modelFilename = (modelPath as NSString).lastPathComponent
        let estimatedClipSize = Double(embeddingWindowSize) * 0.08 // Each embedding covers ~80ms

        os_log("✅ AUTO-DETECTED MODEL CONFIGURATION:")
        os_log("   • Model file: %{public}@", modelFilename)
        os_log("   • Input shape: %{public}@", String(describing: kwsInputShape))
        os_log("   • Embedding window size: %d embeddings", embeddingWindowSize)
        os_log("   • Estimated clip_size: ~%.2fs (%.0fms)", estimatedClipSize, estimatedClipSize * 1000)
        os_log("   • Model expects: [1, %d, 96] = %d elements", embeddingWindowSize, embeddingWindowSize * 96)

        os_log("🔧 RUNTIME CONFIGURATION:")
        os_log("   • Voice Processing: %{public}@", WakeWordConstants.useVoiceProcessing ? "ENABLED" : "DISABLED")
        os_log("   • KWS Threshold: %.3f", WakeWordConstants.kwsThreshold)
        os_log("   • VAD Required Frames: %d", WakeWordConstants.vadRequiredFrames)
        os_log("   • Detailed Frame Logging: %{public}@", WakeWordConstants.enableDetailedFrameLogging ? "ENABLED" : "DISABLED")

        let overrides = WakeWordRuntimeConfig.current
        if overrides.useVoiceProcessing != nil {
            os_log("   ⚠️ Voice Processing overridden via runtime config")
        }

        // Validate feature dimension
        if kwsInputShape[2].intValue != -1 && kwsInputShape[2].intValue != 96 {
            throw WakeWordError.invalidModelShape(kwsInputShape.map { $0.intValue })
        }

        isRunning = true
        reset()
    }

    /// Stop the engine
    public func stop() {
        isRunning = false

        // Log comprehensive session statistics
        if frameCount > 0 {
            let avgInferenceMs = (totalInferenceTime / Double(frameCount)) * 1000.0
            os_log("📊 ========== ENGINE SESSION SUMMARY ==========")
            os_log("📊 Performance:")
            os_log("   • Total frames processed: %d", totalFramesProcessed)
            os_log("   • Successful inferences: %d", frameCount)
            os_log("   • Average inference time: %.2f ms", avgInferenceMs)

            os_log("📊 Data Quality:")
            os_log("   • Bad frames detected: %d (%.2f%%)",
                   badFramesDetected,
                   Float(badFramesDetected) / Float(max(1, totalFramesProcessed)) * 100.0)
            os_log("   • NaN/Inf values scrubbed: %d", nanValuesScrubbed)

            if badFramesDetected > 0 {
                os_log("⚠️  Audio pipeline may have issues - %d frames contained NaN/Inf values", badFramesDetected)
                os_log("   Possible causes:")
                os_log("   1. iOS Voice Processing AGC producing extreme values")
                os_log("   2. Resampler artifacts (48kHz → 16kHz)")
                os_log("   3. Audio buffer corruption")
                os_log("   Try: WakeWordRuntimeConfig.update { $0.useVoiceProcessing = false }")
            } else {
                os_log("✅ Audio pipeline clean - no NaN/Inf values detected")
            }

            os_log("📊 Detection Stats:")
            os_log("   • Wake word detections: %d", detectionEvents.count)
            os_log("   • Max score observed: %.3f", maxScoreObserved)
            os_log("   • Max raw score observed: %.3f", maxRawScoreObserved)
            os_log("📊 ==========================================")
        }

        melSpectrogramSession = nil
        embeddingSession = nil
        wakeWordSession = nil
        reset()
    }

    /// Feed audio buffer to engine
    /// - Parameter buffer: Audio buffer from AVAudioEngine
    public func feed(buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }

        processingQueue.async { [weak self] in
            self?._processBuffer(buffer)
        }
    }

    /// Reset internal state
    public func reset() {
        emaScore = 0.0
        currentScore = 0.0
        vadActiveFrames = 0
        ringBuffer.reset()
        vad.reset()
        melBuffer.removeAll()
        frameCount = 0
        totalInferenceTime = 0
        embeddingBuffer.removeAll()
        totalSamplesProcessed = 0
        detectionEvents.removeAll()
        maxScoreObserved = 0.0
        maxRawScoreObserved = 0.0
        lastWakeTime = 0  // Reset refractory period for offline testing
    }

    /// Process a block of 16 kHz mono Float samples synchronously (offline testing).
    /// The engine must be started prior to calling this API.
    public func processOffline(samples: [Float]) throws {
        guard isRunning else {
            throw WakeWordError.processingError("Engine must be started before feeding samples")
        }
        guard !samples.isEmpty else { return }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: WakeWordConstants.sampleRate, channels: 1) else {
            throw WakeWordError.processingError("Failed to create AVAudioFormat for offline processing")
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw WakeWordError.processingError("Failed to allocate AVAudioPCMBuffer for offline processing")
        }
        let channel = pcmBuffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)

        processingQueue.sync {
            self._processBuffer(pcmBuffer)
        }
    }

    /// Block until the internal processing queue has completed any scheduled work.
    public func waitUntilIdle() {
        processingQueue.sync { }
    }

    // MARK: - Private Processing

    /// Internal buffer processing (runs on processing queue)
    private func _processBuffer(_ buffer: AVAudioPCMBuffer) {
        // Resample if needed
        let processedBuffer: AVAudioPCMBuffer
        if Resampler.isResamplingNeeded(format: buffer.format, targetRate: WakeWordConstants.sampleRate) {
            // Create resampler if not exists
            if resampler == nil {
                do {
                    resampler = try Resampler(inputFormat: buffer.format)
                } catch {
                    os_log("Failed to create resampler: %{public}@", error.localizedDescription)
                    return
                }
            }

            guard let resampled = try? resampler?.resample(buffer) else {
                return
            }
            processedBuffer = resampled
        } else {
            processedBuffer = buffer
        }

        // Convert to Float array
        let samples = AudioConverter.toFloatArray(buffer: processedBuffer)

        // NOTE: Manual AGC removed - relying on iOS voice processing instead
        // If using .voiceChat mode, iOS provides AGC, noise suppression, and echo cancellation
        // If using .default mode and you need AGC, uncomment the code below:

        // Write to ring buffer
        ringBuffer.write(samples)

        // Process VAD first
        _ = vad.process(samples: samples)

        // Process full frames
        while ringBuffer.hasFullFrame(size: WakeWordConstants.frameSizeSamples) {
            let frame = ringBuffer.read(count: WakeWordConstants.frameSizeSamples)
            _processFrame(frame)
        }
    }

    /// Process a single 80ms frame (1280 samples @ 16kHz)
    private func _processFrame(_ frame: [Float]) {
        totalSamplesProcessed += WakeWordConstants.frameSizeSamples
        totalFramesProcessed += 1

        guard let melSession = melSpectrogramSession,
              let embSession = embeddingSession,
              let kwsSession = wakeWordSession else {
            if frameCount < 5 {
                os_log("⚠️ Session not ready: mel=%d emb=%d kws=%d",
                       melSpectrogramSession != nil ? 1 : 0,
                       embeddingSession != nil ? 1 : 0,
                       wakeWordSession != nil ? 1 : 0)
            }
            return
        }

        // Run VAD first to gate KWS
        let vadProb = vad.lastProbability
        let vadActive = vadProb >= WakeWordConstants.vadSpeechThreshold

        // Expose VAD probability and latency for external use (e.g., endpointing, UI)
        self.vadProbability = vadProb
        self.vadLatencyMs = vad.processingLatencyMs

        // Track VAD state for gating
        if vadActive {
            vadActiveFrames += 1
        } else {
            vadActiveFrames = 0
        }

        // Stage 1: Convert raw audio [1, 1280] -> mel-spectrogram [1, 1, ~5 frames, 32]
        // Models expect 16-bit PCM magnitude; scale normalized floats back to that range.
        let pcmFrame = frame.map { $0 * WakeWordConstants.pcm16AmplitudeScale }

        #if DEBUG
        // 📊 DEBUG: Calculate frame statistics BEFORE validation/scrubbing
        let frameStats = calculateFrameStatistics(frame: pcmFrame)

        // 📊 DEBUG: Log detailed frame statistics when enabled
        if WakeWordConstants.enableDetailedFrameLogging {
            if totalFramesProcessed % 50 == 0 || frameStats.hasNaN {
                os_log("📊 Frame #%d: RMS=%.2f, range=[%.2f, %.2f], mean=%.2f, hasNaN=%d",
                       totalFramesProcessed, frameStats.rms, frameStats.min, frameStats.max,
                       frameStats.mean, frameStats.hasNaN ? 1 : 0)
            }
        }

        // Add to circular buffer for pattern analysis
        addFrameMetadata(index: totalFramesProcessed, stats: frameStats)
        #else
        let frameStats = calculateFrameStatistics(frame: pcmFrame)
        #endif

        // CRITICAL: Validate and SCRUB PCM frame BEFORE passing to ONNX
        // This prevents "Invalid frame dimension" error spam from ONNX Runtime
        let (sanitizedFrame, scrubbedCount) = sanitizeFrame(pcmFrame)

        if scrubbedCount > 0 {
            badFramesDetected += 1
            nanValuesScrubbed += scrubbedCount

            #if DEBUG
            // Log scrubbing event with context
            os_log("🧹 Frame #%d: Scrubbed %d NaN/Inf values (total bad frames: %d/%d = %.1f%%)",
                   totalFramesProcessed, scrubbedCount, badFramesDetected, totalFramesProcessed,
                   Float(badFramesDetected) / Float(max(1, totalFramesProcessed)) * 100.0)

            // Log recent frame history when bad frame detected
            if WakeWordConstants.enableDetailedFrameLogging {
                logRecentFrameHistory()
            }
            #endif
        }

        // Use sanitized frame for ONNX inference
        let cleanPcmFrame = sanitizedFrame

        let melFeatures: [NSNumber]
        do {
            melFeatures = try melSession.run(
                withInput: cleanPcmFrame,
                inputSize: cleanPcmFrame.count,
                outputSize: 8192  // Conservative estimate
            )
        } catch {
            // ALWAYS log mel-spec errors with enhanced diagnostics
            os_log("❌ Mel-spectrogram inference error (frame %d): %{public}@",
                   frameCount, error.localizedDescription)
            os_log("   Input stats: count=%d, RMS=%.2f, range=[%.2f, %.2f]",
                   cleanPcmFrame.count, frameStats.rms, frameStats.min, frameStats.max)
            os_log("   Scrubbed: %d values in this frame", scrubbedCount)
            return
        }

        // Apply mel-spectrogram scaling: (x / 10.0) + 2.0 and append to buffer
        let scaledMels = melFeatures.map { ($0.floatValue / 10.0) + 2.0 }

        // Validate mel features before appending (prevent buffer corruption)
        if scaledMels.contains(where: { !$0.isFinite }) {
            return  // Skip bad mel features
        }

        melBuffer.append(contentsOf: scaledMels)

        // Calculate how many mel frames we have (each frame = 32 values)
        let currentMelFrames = melBuffer.count / numMels

        // Need at least 76 frames to run embedding model
        guard currentMelFrames >= melWindowSize else {
            // Still accumulating, no prediction yet
            return
        }

        // Run three-stage inference with sliding window
        let startTime = CFAbsoluteTimeGetCurrent()

        // Extract exactly 76 frames worth of mels
        let melWindow = Array(melBuffer.prefix(melWindowSize * numMels))

        // DEBUG: Validate mel window before passing to embedding model
        #if DEBUG
        if WakeWordConstants.enableInferenceValidation {
            if melWindow.count != melWindowSize * numMels {
                os_log("❌ Mel window size mismatch (frame %d): got %d, expected %d",
                       frameCount, melWindow.count, melWindowSize * numMels)
                _advanceMelBuffer()
                return
            }

            if melWindow.contains(where: { !$0.isFinite }) {
                os_log("❌ Mel window contains non-finite values (frame %d)!", frameCount)
                _advanceMelBuffer()
                return
            }
        }
        #endif

        // Stage 2: Convert mel features [1, 76, 32, 1] -> embedding vector [1, 1, 1, 96]
        let embeddings: [NSNumber]
        do {
            embeddings = try embSession.run(
                withInput: melWindow,
                inputSize: melWindow.count,
                outputSize: embeddingDimension
            )
        } catch {
            // ALWAYS log embedding errors
            os_log("❌ Embedding inference error (frame %d): %{public}@",
                   frameCount, error.localizedDescription)
            os_log("   Debug: melWindow.count=%d, melBuffer.count=%d",
                   melWindow.count, melBuffer.count)
            _advanceMelBuffer()
            return
        }

        // Convert to Float array and accumulate embeddings for wake model
        let embeddingVector = embeddings.map { $0.floatValue }
        if embeddingVector.count != embeddingDimension {
            // ALWAYS log size mismatches
            os_log("❌ Unexpected embedding size: %d (expected %d)",
                   embeddingVector.count, embeddingDimension)
            _advanceMelBuffer()
            return
        }
        embeddingBuffer.append(contentsOf: embeddingVector)

        // Advance mel buffer regardless of embedding readiness to keep sliding
        _advanceMelBuffer()

        // Safety check: embeddingWindowSize must be set (happens during start())
        guard embeddingWindowSize > 0 else {
            return
        }

        let requiredEmbeddingSamples = embeddingWindowSize * embeddingDimension
        let embeddingFrames = embeddingBuffer.count / embeddingDimension

        #if DEBUG
        // Log embedding buffer accumulation (only while filling)
        if embeddingFrames < embeddingWindowSize && embeddingFrames % 4 == 0 {
            os_log("📊 Embedding buffer: %d embeddings (need %d to proceed)",
                   embeddingFrames, embeddingWindowSize)
        }
        #endif

        guard embeddingBuffer.count >= requiredEmbeddingSamples else {
            return
        }

        // Log ONLY the very first time we reach wake word detection
        // (frameCount hasn't incremented yet, so check if it's still 0)
        if frameCount == 0 {
            os_log("🎯 Embedding buffer ready! Proceeding to wake word detection...")
        }

        let embeddingWindow = Array(embeddingBuffer.prefix(requiredEmbeddingSamples))

        // DEBUG: Validate embeddingWindow before passing to ONNX
        #if DEBUG
        if WakeWordConstants.enableInferenceValidation {
            guard embeddingWindow.count == requiredEmbeddingSamples else {
                os_log("❌ Embedding window size mismatch: got %d, expected %d",
                       embeddingWindow.count, requiredEmbeddingSamples)
                _advanceEmbeddingBuffer()
                return
            }

            // Check for invalid values
            if embeddingWindow.contains(where: { !$0.isFinite }) {
                os_log("❌ Embedding window contains non-finite values!")
                _advanceEmbeddingBuffer()
                return
            }
        }
        #endif

        // Stage 3: Run wake word detection on embeddings [1, embeddingWindowSize, 96] -> score
        let output: [NSNumber]
        do {
            output = try kwsSession.run(
                withInput: embeddingWindow,
                inputSize: embeddingWindow.count,
                outputSize: 1
            )
        } catch {
            // ALWAYS log wake word inference errors with details
            os_log("❌ Wake word inference error (frame %d): %{public}@",
                   frameCount, error.localizedDescription)
            os_log("   Debug: embeddingWindowSize=%d, bufferCount=%d, windowCount=%d",
                   embeddingWindowSize, embeddingBuffer.count, embeddingWindow.count)
            _advanceEmbeddingBuffer()
            return
        }

        let baseRawScore = output.first?.floatValue ?? 0.0
        var combinedRawScore = baseRawScore
        var rawScoreTrimmed: Float?

        if WakeWordConstants.kwsShortWindowEmbeddings > 0 &&
            WakeWordConstants.kwsShortWindowEmbeddings < embeddingWindowSize {
            let trimStart = WakeWordConstants.kwsShortWindowEmbeddings * embeddingDimension
            if trimStart < embeddingWindow.count {
                var trimmedWindow = embeddingWindow
                for idx in trimStart..<trimmedWindow.count {
                    trimmedWindow[idx] = 0.0
                }

                // DEBUG: Validate trimmed window before running inference
                #if DEBUG
                let validationPassed = WakeWordConstants.enableInferenceValidation ? {
                    if trimmedWindow.count != requiredEmbeddingSamples {
                        os_log("⚠️ Trimmed window size mismatch: got %d, expected %d",
                               trimmedWindow.count, requiredEmbeddingSamples)
                        return false
                    }
                    if trimmedWindow.contains(where: { !$0.isFinite }) {
                        os_log("⚠️ Trimmed window contains non-finite values!")
                        return false
                    }
                    return true
                }() : true
                #else
                let validationPassed = true
                #endif

                if validationPassed {
                    // Trimmed window is valid, run inference
                    do {
                        let trimmedOutput = try kwsSession.run(
                            withInput: trimmedWindow,
                            inputSize: trimmedWindow.count,
                            outputSize: 1
                        )
                        rawScoreTrimmed = trimmedOutput.first?.floatValue ?? 0.0
                        if baseRawScore >= WakeWordConstants.kwsShortWindowMinBaseScore {
                            combinedRawScore = max(combinedRawScore, rawScoreTrimmed ?? combinedRawScore)
                        }
                    } catch {
                        os_log("⚠️ Short-window wake inference error (frame %d): %{public}@",
                               frameCount, error.localizedDescription)
                        os_log("   Debug: trimStart=%d, trimmedWindow.count=%d",
                               trimStart, trimmedWindow.count)
                    }
                }
            }
        }

        let inferenceTime = CFAbsoluteTimeGetCurrent() - startTime
        totalInferenceTime += inferenceTime
        frameCount += 1

        // Extract score
        let rawScore = combinedRawScore
        maxRawScoreObserved = max(maxRawScoreObserved, rawScore)

        // Log first successful wake word inference
        if frameCount == 1 {
            os_log("🎉 FIRST COMPLETE INFERENCE! raw_score=%.3f, output_count=%d",
                   rawScore, output.count)
        }

        // Apply EMA smoothing
        latestRawScore = rawScore
        emaScore = (1.0 - WakeWordConstants.kwsEMAAlpha) * emaScore +
                   WakeWordConstants.kwsEMAAlpha * rawScore

        // Favor the instantaneous spike so a wake word embedded in longer speech still fires.
        let detectionScore = max(rawScore, emaScore)
        currentScore = detectionScore
        maxScoreObserved = max(maxScoreObserved, detectionScore)

        // Check for wake detection
        _checkWakeDetection(score: detectionScore, vadActive: vadActive)

        // Slide embedding buffer for next window
        _advanceEmbeddingBuffer()

        #if DEBUG
        // Log periodically (reduced frequency for CPU optimization)
        if frameCount % 300 == 0 {
            let trimmedLog: String
            if let trimmed = rawScoreTrimmed,
               baseRawScore >= WakeWordConstants.kwsShortWindowMinBaseScore {
                trimmedLog = String(format: "%.3f", trimmed)
            } else if rawScoreTrimmed != nil {
                trimmedLog = "ignored"
            } else {
                trimmedLog = "—"
            }
            os_log("🔍 KWS: frame=%d, raw=%.3f (base=%.3f, trim=%@), ema=%.3f, detect=%.3f, VAD=%.2f (active=%d frames), inf=%.1fms",
                   frameCount, rawScore, baseRawScore, trimmedLog, emaScore, detectionScore, vadProb, vadActiveFrames, inferenceTime * 1000.0)
        }
        #endif
    }

    /// Check if wake word should be triggered
    private func _checkWakeDetection(score: Float, vadActive: Bool) {
        // Check refractory period
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastWakeTime < WakeWordConstants.refractoryPeriodSec {
            return
        }

        // Wake detection criteria:
        // 1. Score above threshold
        // 2. VAD active for required number of frames
        let scoreAboveThreshold = score >= WakeWordConstants.kwsThreshold
        let vadGatePassed = vadActiveFrames >= WakeWordConstants.vadRequiredFrames

        if scoreAboveThreshold && vadGatePassed {
            // WAKE DETECTED!
            os_log("🎯 WAKE WORD DETECTED! score=%.3f, vadFrames=%d", score, vadActiveFrames)

            let event = WakeDetectionEvent(
                score: score,
                rawScore: latestRawScore,
                emaScore: emaScore,
                vadActiveFrames: vadActiveFrames,
                sampleIndex: totalSamplesProcessed,
                frameIndex: frameCount
            )
            detectionEvents.append(event)

            if let handler = onWakeEvent {
                handler(event)
            }

            lastWakeTime = now
            vadActiveFrames = 0 // Reset for next detection

            // Trigger callback on main thread
            DispatchQueue.main.async { [weak self] in
                self?.onWake?()
            }
        } else {
            #if DEBUG
            // Log near misses to help debug
            if score > 0.3 {
                if scoreAboveThreshold && !vadGatePassed {
                    os_log("⚠️ Near miss: score=%.3f (✅) but VAD frames=%d (need %d)",
                           score, vadActiveFrames, WakeWordConstants.vadRequiredFrames)
                } else if !scoreAboveThreshold && vadGatePassed {
                    os_log("⚠️ Near miss: score=%.3f (need %.2f) but VAD frames=%d (✅)",
                           score, WakeWordConstants.kwsThreshold, vadActiveFrames)
                }
            }
            #endif
        }
    }
}

private extension OpenWakeWordEngine {
    /// Advance mel buffer by configured hop size
    func _advanceMelBuffer() {
        let removeCount = melStepSize * numMels
        guard removeCount > 0 else { return }

        if melBuffer.count >= removeCount {
            melBuffer.removeFirst(removeCount)
        } else if !melBuffer.isEmpty {
            melBuffer.removeAll()
        }
    }

    /// Advance embedding buffer by configured hop size
    func _advanceEmbeddingBuffer() {
        let removeCount = embeddingStepSize * embeddingDimension
        guard removeCount > 0 else { return }

        if embeddingBuffer.count >= removeCount {
            embeddingBuffer.removeFirst(removeCount)
        } else if !embeddingBuffer.isEmpty {
            embeddingBuffer.removeAll()
        }
    }

    // MARK: - Frame Validation & Diagnostics

    /// Frame statistics for debugging
    struct FrameStatistics {
        let rms: Float
        let max: Float
        let min: Float
        let mean: Float
        let hasNaN: Bool
    }

    /// Calculate comprehensive statistics for a frame
    func calculateFrameStatistics(frame: [Float]) -> FrameStatistics {
        var sum: Float = 0.0
        var sumSquared: Float = 0.0
        var maxVal: Float = -.infinity
        var minVal: Float = .infinity
        var hasNaN = false

        for sample in frame {
            if !sample.isFinite {
                hasNaN = true
                continue  // Skip NaN/Inf in calculations
            }
            sum += sample
            sumSquared += sample * sample
            maxVal = max(maxVal, sample)
            minVal = min(minVal, sample)
        }

        let count = Float(frame.count)
        let mean = sum / count
        let rms = sqrtf(sumSquared / count)

        return FrameStatistics(
            rms: rms,
            max: maxVal.isFinite ? maxVal : 0.0,
            min: minVal.isFinite ? minVal : 0.0,
            mean: mean.isFinite ? mean : 0.0,
            hasNaN: hasNaN
        )
    }

    /// Sanitize frame by replacing NaN/Inf with zeros
    /// Returns: (sanitized frame, count of scrubbed values)
    func sanitizeFrame(_ frame: [Float]) -> ([Float], Int) {
        var scrubbedCount = 0
        let sanitized = frame.map { value -> Float in
            if !value.isFinite {
                scrubbedCount += 1
                return 0.0
            }
            return value
        }
        return (sanitized, scrubbedCount)
    }

    /// Add frame metadata to circular buffer
    func addFrameMetadata(index: Int, stats: FrameStatistics) {
        let metadata = (index: index, rms: stats.rms, max: stats.max, min: stats.min, hasNaN: stats.hasNaN)
        frameMetadataBuffer.append(metadata)

        // Keep buffer at fixed size (circular)
        if frameMetadataBuffer.count > frameMetadataBufferSize {
            frameMetadataBuffer.removeFirst()
        }
    }

    /// Log recent frame history (last N frames from circular buffer)
    func logRecentFrameHistory() {
        os_log("📜 Recent frame history (last %d frames):", frameMetadataBuffer.count)
        for (i, metadata) in frameMetadataBuffer.enumerated() {
            os_log("   [%d] Frame #%d: RMS=%.2f, range=[%.2f, %.2f], NaN=%d",
                   i, metadata.index, metadata.rms, metadata.min, metadata.max, metadata.hasNaN ? 1 : 0)
        }
    }
}

// MARK: - Errors

public enum WakeWordError: LocalizedError {
    case modelLoadFailed(String)
    case invalidModelShape([Int])
    case processingError(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .invalidModelShape(let shape):
            return "Invalid model input shape: \(shape)"
        case .processingError(let reason):
            return "Processing error: \(reason)"
        }
    }
}

// MARK: - 📍 INTEGRATION GUIDE

/// How to use OpenWakeWordEngine in your app:
///
/// ```swift
/// // 1. Initialize engine with all three model paths
/// let modelPath = Bundle.main.path(forResource: "hey_jarvis", ofType: "onnx")!
/// let melPath = Bundle.main.path(forResource: "melspectrogram", ofType: "onnx")!
/// let embPath = Bundle.main.path(forResource: "embedding_model", ofType: "onnx")!
/// let engine = OpenWakeWordEngine(modelPath: modelPath, melSpectrogramPath: melPath, embeddingModelPath: embPath)
///
/// // 2. Set wake callback
/// engine.onWake = { [weak self] in
///     print("Wake word detected!")
///     self?.handleWakeDetected()
/// }
///
/// // 3. Start engine
/// try engine.start()
///
/// // 4. Feed audio from AVAudioEngine tap
/// inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
///     engine.feed(buffer: buffer)
/// }
///
/// // 5. Stop when done
/// engine.stop()
/// ```
///
/// **Performance Notes:**
/// - Inference time on iPhone 11 (A13): ~10-25ms per 80ms frame (three-stage pipeline)
/// - With CoreML EP + ANE: ~6-15ms per frame
/// - CPU usage while listening: ~12-18%
/// - Memory footprint: ~60-80 MB (three models + buffers)
///
/// **Tuning Tips:**
/// - Adjust `WakeWordConstants.kwsThreshold` for sensitivity
/// - Increase `vadRequiredFrames` to reduce false accepts
/// - Monitor `currentScore` property for debugging
///
/// **Model Requirements:**
/// - Mel-spectrogram model: Input [1, 1280] raw audio -> Output [1, 1, frames, 32] mel features
/// - Embedding model: Input [1, 76, 32, 1] mel features -> Output [1, 1, 1, 96] embeddings (per frame)
/// - Wake word model: Input [1, N, 96] embeddings -> Output [1] score
///   - N = auto-detected from model (e.g., clip_size: 1.4s→11, 2.0s→16, 3.0s→28)
/// - All models use Float32
/// - Expected sample rate: 16kHz
/// - Frame size: 80ms (1280 samples)

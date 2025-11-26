//
//  VoiceActivityDetector.swift
//  WakeWordKit
//
//  Protocol for Voice Activity Detection (VAD) engines.
//  Used to gate wake word detection and perform endpointing.
//

import AVFoundation
import Foundation

/// Protocol for Voice Activity Detection (VAD) engines
///
/// 📍 INTEGRATION POINT: This protocol allows you to swap VAD implementations
/// without changing your wake word logic.
///
/// Example implementations:
/// - `SileroVAD` (CoreML or ONNX)
/// - `WebRTCVAD` (native port)
/// - `AmplitudeVAD` (simple threshold-based)
///
public protocol VoiceActivityDetector: AnyObject {

    /// Feed audio samples to the VAD
    /// - Parameter samples: Float32 audio samples (mono, 16kHz expected)
    /// - Returns: Speech probability (0.0 = silence, 1.0 = speech)
    func process(samples: [Float]) -> Float

    /// Check if currently in speech state
    /// Uses internal threshold to determine speech vs. silence
    var isSpeech: Bool { get }

    /// Check if we've been silent for at least the specified duration
    /// Useful for endpointing (detecting end of utterance)
    /// - Parameter durationMs: Minimum silence duration in milliseconds
    /// - Returns: True if silence duration exceeds threshold
    func isSilent(durationMs: Double) -> Bool

    /// Reset internal state
    func reset()

    /// Last computed speech probability (0.0 - 1.0)
    var lastProbability: Float { get }
}

/// 📍 INTEGRATION POINT: Basic usage example
///
/// ```swift
/// let vad = SileroVAD(modelPath: "path/to/silero_vad.mlmodelc")
///
/// // In your audio processing loop:
/// let samples: [Float] = convertToFloat(buffer)
/// let speechProb = vad.process(samples: samples)
///
/// if vad.isSpeech {
///     print("Speech detected: \(speechProb)")
/// }
///
/// // For endpointing:
/// if vad.isSilent(durationMs: 500) {
///     print("User stopped speaking")
///     finalizeCommand()
/// }
/// ```

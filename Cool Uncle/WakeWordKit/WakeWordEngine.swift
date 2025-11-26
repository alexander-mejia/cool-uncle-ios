//
//  WakeWordEngine.swift
//  WakeWordKit
//
//  Protocol for wake word detection engines.
//  Implement this protocol to support different KWS backends (OpenWakeWord, Porcupine, etc.)
//

import AVFoundation
import Foundation

/// Protocol for wake word detection engines
///
/// 📍 INTEGRATION POINT: This protocol allows you to swap KWS implementations
/// without changing your audio pipeline code.
///
/// Example implementations:
/// - `OpenWakeWordEngine` (ONNX-based)
/// - `PorcupineEngine` (Picovoice)
/// - `SnowboyEngine` (Kitt.ai)
///
public protocol WakeWordEngine: AnyObject {

    /// Called when wake word is detected
    /// This closure is invoked on the main thread
    var onWake: (() -> Void)? { get set }

    /// Feed an audio buffer to the engine
    /// - Parameter buffer: Audio buffer from AVAudioEngine tap
    /// - Note: Engine handles resampling to 16kHz mono internally if needed
    func feed(buffer: AVAudioPCMBuffer)

    /// Start the engine (allocate resources, load models)
    func start() throws

    /// Stop the engine (release resources)
    func stop()

    /// Current wake word score (0.0 - 1.0)
    /// Useful for debugging and UI visualization
    var currentScore: Float { get }

    /// Is the engine currently active and processing audio?
    var isRunning: Bool { get }

    /// Reset internal state (useful after wake detection to prevent double-fire)
    func reset()
}

/// 📍 INTEGRATION POINT: Basic usage example
///
/// ```swift
/// let engine = OpenWakeWordEngine(modelPath: "path/to/oww_wake.onnx")
///
/// engine.onWake = { [weak self] in
///     print("Wake word detected!")
///     self?.handleWakeDetected()
/// }
///
/// try engine.start()
///
/// // In your AVAudioEngine tap:
/// inputNode.installTap(...) { buffer, _ in
///     engine.feed(buffer: buffer)
/// }
/// ```

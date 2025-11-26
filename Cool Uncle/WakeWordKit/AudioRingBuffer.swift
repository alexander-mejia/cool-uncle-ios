//
//  AudioRingBuffer.swift
//  WakeWordKit
//
//  Circular buffer for audio samples to maintain sliding window of 16kHz mono audio.
//  Handles frame alignment for wake word detection (80ms = 1280 samples @ 16kHz).
//

import Foundation
import os.log

/// Thread-safe circular buffer for Float audio samples
///
/// 📍 INTEGRATION POINT: This buffer manages audio buffering for wake word detection.
/// It accumulates audio samples and provides aligned frames for processing.
///
/// Usage:
/// 1. Push incoming audio samples via `write()`
/// 2. Check if full frame available via `availableSamples >= frameSize`
/// 3. Read aligned frames via `read(count:)`
///
public class AudioRingBuffer {

    private var buffer: [Float]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var availableCount: Int = 0
    private let lock = NSLock()

    /// Create a ring buffer with specified capacity
    /// - Parameter capacity: Maximum number of samples to store (recommend 2-3x frame size)
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Convenience initializer for wake word use case
    /// - Parameter frameSize: Target frame size (e.g., 1280 samples for 80ms @ 16kHz)
    /// - Parameter multiplier: How many frames to buffer (default: 3)
    public convenience init(frameSize: Int, multiplier: Int = 3) {
        self.init(capacity: frameSize * multiplier)
    }

    /// Write samples to the buffer
    /// - Parameter samples: Array of Float samples to write
    /// - Returns: Number of samples actually written (may be less if buffer full)
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let samplesToWrite = min(samples.count, capacity - availableCount)

        for i in 0..<samplesToWrite {
            buffer[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
        }

        availableCount += samplesToWrite

        if samplesToWrite < samples.count {
            os_log("AudioRingBuffer: Dropped %d samples (buffer full)", samples.count - samplesToWrite)
        }

        return samplesToWrite
    }

    /// Read samples from the buffer without removing them
    /// - Parameter count: Number of samples to peek
    /// - Returns: Array of samples (may be less than requested if not enough available)
    public func peek(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let samplesToRead = min(count, availableCount)
        var result = [Float](repeating: 0, count: samplesToRead)

        var idx = readIndex
        for i in 0..<samplesToRead {
            result[i] = buffer[idx]
            idx = (idx + 1) % capacity
        }

        return result
    }

    /// Read and consume samples from the buffer
    /// - Parameter count: Number of samples to read
    /// - Returns: Array of samples (may be less than requested if not enough available)
    public func read(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let samplesToRead = min(count, availableCount)
        var result = [Float](repeating: 0, count: samplesToRead)

        for i in 0..<samplesToRead {
            result[i] = buffer[readIndex]
            readIndex = (readIndex + 1) % capacity
        }

        availableCount -= samplesToRead

        return result
    }

    /// Number of samples currently available for reading
    public var availableSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return availableCount
    }

    /// Check if a full frame is available
    /// - Parameter frameSize: Required frame size
    /// - Returns: True if at least frameSize samples are available
    public func hasFullFrame(size: Int) -> Bool {
        return availableSamples >= size
    }

    /// Clear the buffer
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        writeIndex = 0
        readIndex = 0
        availableCount = 0
    }

    /// Current fill percentage (0.0 - 1.0)
    public var fillPercentage: Float {
        lock.lock()
        defer { lock.unlock() }
        return Float(availableCount) / Float(capacity)
    }
}

/// 📍 INTEGRATION POINT: Usage in audio processing pipeline
///
/// ```swift
/// let buffer = AudioRingBuffer(frameSize: 1280, multiplier: 3)
///
/// // In your AVAudioEngine tap:
/// inputNode.installTap(...) { avBuffer, _ in
///     // Convert to Float array
///     let samples = convertToFloat(avBuffer)
///
///     // Write to ring buffer
///     buffer.write(samples)
///
///     // Process full frames
///     while buffer.hasFullFrame(size: 1280) {
///         let frame = buffer.read(count: 1280)
///         wakeWordEngine.processFrame(frame)
///     }
/// }
/// ```

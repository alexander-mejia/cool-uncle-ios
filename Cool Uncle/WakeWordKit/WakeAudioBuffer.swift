//
//  WakeAudioBuffer.swift
//  WakeWordKit
//
//  Circular buffer for retaining recent audio samples so that we can feed
//  a short pre-roll into speech recognition when the wake word fires.
//

import Foundation

/// Fixed-size ring buffer that stores Float32 audio samples at a known sample rate.
/// Used for supplying a brief pre-roll (e.g., 500-800 ms) to the STT request so that
/// the first post-wake word is never clipped.
final class WakeAudioBuffer {

    private let capacity: Int
    private let sampleRate: Double
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var storedSamples: Int = 0
    private var totalSamplesWritten: Int = 0  // Cumulative count for timestamp alignment
    private let lock = NSLock()

    init(durationSeconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        let totalSamples = max(1, Int(durationSeconds * sampleRate))
        self.capacity = totalSamples
        self.buffer = [Float](repeating: 0, count: totalSamples)
    }

    /// Reset the buffer to an empty state.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        storedSamples = 0
    }

    /// Write samples into the buffer, discarding the oldest when capacity is exceeded.
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            if storedSamples < capacity {
                storedSamples += 1
            }
        }
        totalSamplesWritten += samples.count
    }

    /// Returns the total number of samples written since initialization.
    /// Used for correlating OpenWakeWord's sampleIndex with ring buffer position.
    func getTotalSamplesWritten() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return totalSamplesWritten
    }

    /// Read the most recent samples covering the requested duration (seconds).
    /// If the buffer does not contain that many samples yet, it returns everything available.
    func readLast(seconds: Double) -> [Float] {
        guard seconds > 0 else { return [] }

        lock.lock()
        defer { lock.unlock() }

        guard storedSamples > 0 else { return [] }

        let requestedSamples = min(storedSamples, Int(seconds * sampleRate))
        guard requestedSamples > 0 else { return [] }

        var result = [Float](repeating: 0, count: requestedSamples)
        let startIndex = (writeIndex - requestedSamples + capacity) % capacity

        if startIndex + requestedSamples <= capacity {
            for i in 0..<requestedSamples {
                result[i] = buffer[startIndex + i]
            }
        } else {
            let firstChunk = capacity - startIndex
            for i in 0..<firstChunk {
                result[i] = buffer[startIndex + i]
            }
            let secondChunk = requestedSamples - firstChunk
            for i in 0..<secondChunk {
                result[firstChunk + i] = buffer[i]
            }
        }

        return result
    }
}

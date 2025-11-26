//
//  AudioConverter.swift
//  WakeWordKit
//
//  Utilities for converting between audio formats (Int16 ↔ Float32, mono/stereo, etc.)
//

import AVFoundation
import Accelerate

/// Minimal audio format conversion utilities used by the wake word pipeline.
public struct AudioConverter {

    // MARK: - PCM Buffer to Float Array

    /// Convert AVAudioPCMBuffer to Float32 array (mono)
    /// - Parameter buffer: Input audio buffer
    /// - Returns: Float32 array normalized to [-1.0, 1.0]
    public static func toFloatArray(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if channelCount == 1 {
            // Already mono, just copy
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            // Stereo to mono: average channels
            return stereoToMono(
                left: UnsafeBufferPointer(start: channelData[0], count: frameLength),
                right: UnsafeBufferPointer(start: channelData[1], count: frameLength)
            )
        }
    }

    /// Convert stereo to mono by averaging channels (using Accelerate for performance)
    /// - Parameters:
    ///   - left: Left channel samples
    ///   - right: Right channel samples
    /// - Returns: Mono samples (averaged)
    private static func stereoToMono(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> [Float] {
        let count = min(left.count, right.count)
        var summed = [Float](repeating: 0, count: count)
        var mono = [Float](repeating: 0, count: count)

        // Use Accelerate for SIMD-optimized averaging
        // Step 1: summed = left + right
        vDSP_vadd(left.baseAddress!, 1, right.baseAddress!, 1, &summed, 1, vDSP_Length(count))

        // Step 2: mono = summed / 2
        var divisor: Float = 2.0
        vDSP_vsdiv(&summed, 1, &divisor, &mono, 1, vDSP_Length(count))

        return mono
    }

}

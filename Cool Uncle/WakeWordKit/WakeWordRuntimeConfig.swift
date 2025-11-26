//
//  WakeWordRuntimeConfig.swift
//  WakeWordKit
//
//  Runtime overrides to support automated evaluation harnesses.
//

import Foundation
import Dispatch

/// Mutable runtime overrides for wake word tuning parameters.
/// Defaults mirror the values documented in `WakeWordConstants`.
public struct WakeWordRuntimeOverrides {
    public var kwsThreshold: Float?
    public var kwsShortWindowEmbeddings: Int?
    public var kwsShortWindowMinBaseScore: Float?
    public var vadRequiredFrames: Int?

    /// Audio processing toggles (added for debugging "Invalid frame dimension" errors)
    public var useVoiceProcessing: Bool?

    /// Use .videoRecording audio mode for mode-level voice processing
    /// 🎯 A/B TESTING: Compare engine-level vs mode-level processing
    public var useVideoRecordingMode: Bool?

    /// Use .measurement mode for lower CPU usage (8-12% savings)
    /// ⚠️ TRADEOFF: Disables AGC, noise suppression, echo cancellation
    public var useMeasurementMode: Bool?

    /// Temporal integration tuning (added for automated experiments)
    public var useTemporalMaxPooling: Bool?
    public var temporalWindowFrames: Int?
    public var temporalPoolingWeight: Float?

    public init(
        kwsThreshold: Float? = nil,
        kwsShortWindowEmbeddings: Int? = nil,
        kwsShortWindowMinBaseScore: Float? = nil,
        vadRequiredFrames: Int? = nil,
        useVoiceProcessing: Bool? = nil,
        useVideoRecordingMode: Bool? = nil,
        useMeasurementMode: Bool? = nil,
        useTemporalMaxPooling: Bool? = nil,
        temporalWindowFrames: Int? = nil,
        temporalPoolingWeight: Float? = nil
    ) {
        self.kwsThreshold = kwsThreshold
        self.kwsShortWindowEmbeddings = kwsShortWindowEmbeddings
        self.kwsShortWindowMinBaseScore = kwsShortWindowMinBaseScore
        self.vadRequiredFrames = vadRequiredFrames
        self.useVoiceProcessing = useVoiceProcessing
        self.useVideoRecordingMode = useVideoRecordingMode
        self.useMeasurementMode = useMeasurementMode
        self.useTemporalMaxPooling = useTemporalMaxPooling
        self.temporalWindowFrames = temporalWindowFrames
        self.temporalPoolingWeight = temporalPoolingWeight
    }
}

/// Global runtime configuration entry point.
public enum WakeWordRuntimeConfig {
    private static let queue = DispatchQueue(label: "com.wakewordkit.runtime-config", qos: .userInitiated)
    private static var overrides = WakeWordRuntimeOverrides()

    /// Apply overrides atomically (replaces any existing overrides).
    public static func apply(_ newOverrides: WakeWordRuntimeOverrides) {
        queue.sync {
            overrides = newOverrides
        }
    }

    /// Mutate overrides atomically.
    public static func update(_ block: (inout WakeWordRuntimeOverrides) -> Void) {
        queue.sync {
            block(&overrides)
        }
    }

    /// Reset overrides back to defaults.
    public static func reset() {
        queue.sync {
            overrides = WakeWordRuntimeOverrides()
        }
    }

    /// Current overrides snapshot.
    static var current: WakeWordRuntimeOverrides {
        queue.sync { overrides }
    }
}

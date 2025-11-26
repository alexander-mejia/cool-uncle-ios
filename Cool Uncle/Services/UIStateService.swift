import SwiftUI

/// Manages UI state for transient status messages and wake word timer
/// This service provides a single source of truth for:
/// - Transient status (iMessage-style pulsing text that doesn't persist)
/// - Timer countdown ring progress (0.0 to 1.0)
@MainActor
class UIStateService: ObservableObject {
    // MARK: - Transient Status

    /// Current transient status message (nil = hidden)
    /// This is the "User is typing..." equivalent for AI processing
    /// Examples: "Asking the AI...", "Searching for a platformer..."
    @Published var transientStatus: String? = nil

    /// Show transient status message
    /// - Parameter message: Status text to display (e.g., "Searching...")
    func showStatus(_ message: String) {
        transientStatus = message
    }

    /// Hide transient status message
    func hideStatus() {
        transientStatus = nil
    }

    // MARK: - Timer Tracking

    /// Time remaining in wake word recording (seconds)
    /// Updated by SpeechService during wake word recording
    @Published var recordingTimeRemaining: Double = 0.0

    /// Maximum duration for wake word recording (seconds)
    /// Default: 5.0 seconds (matches multi-layer VAD failsafe)
    @Published var recordingMaxDuration: Double = 5.0

    /// Progress for countdown ring (0.0 = empty, 1.0 = full)
    /// Used to drive visual timer ring around mic button
    var recordingProgress: Double {
        guard recordingMaxDuration > 0 else { return 0 }
        return recordingTimeRemaining / recordingMaxDuration
    }

    /// Reset timer to default state
    func resetTimer() {
        recordingTimeRemaining = 0.0
        recordingMaxDuration = 5.0
    }
}

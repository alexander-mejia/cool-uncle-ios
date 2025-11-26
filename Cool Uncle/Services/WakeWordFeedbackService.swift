import AVFoundation
import SwiftUI

/// Provides audio and visual feedback for wake word detection
/// - Plays subtle chime when "Hey Mister" is detected
/// - Uses bundled wakewordtone.wav file
@MainActor
class WakeWordFeedbackService: ObservableObject {
    private var audioPlayer: AVAudioPlayer?

    /// Play wake word detection chime
    /// Called by SpeechService when wake word is detected
    func playWakeWordChime() {
        // Use bundled WAV file instead of programmatic generation
        guard let chimeURL = Bundle.main.url(forResource: "wakewordtone", withExtension: "wav") else {
            AppLogger.connection("⚠️ Wake word chime file not found in bundle")
            return
        }

        let audioSession = AVAudioSession.sharedInstance()

        do {
            // Ensure audio session is active for playback
            // The session is already configured as .playAndRecord + .videoRecording by SpeechService
            // We just need to make sure it's active and outputting to speaker
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            #if DEBUG
            AppLogger.verbose("🔧 [DEBUG] Chime audio session: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue), route=\(audioSession.currentRoute.outputs.first?.portType.rawValue ?? "unknown")")
            #endif

            audioPlayer = try AVAudioPlayer(contentsOf: chimeURL)

            // CRITICAL: Set audio category to mix with others and default to speaker
            audioPlayer?.setVolume(0.8, fadeDuration: 0)  // 80% volume, no fade

            let success = audioPlayer?.play() ?? false

            if success {
                AppLogger.standard("🔔 Wake word chime played (duration: \(audioPlayer?.duration ?? 0)s)")
            } else {
                AppLogger.connection("⚠️ Chime play() returned false")
            }
        } catch {
            AppLogger.connection("⚠️ Failed to play chime: \(error)")
        }
    }

}

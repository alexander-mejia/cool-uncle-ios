import Foundation
import AVFoundation

@MainActor
class AVSpeechService: NSObject, ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var currentText: String = ""
    
    private var speechSynthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }
    
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil) {
        guard !text.isEmpty else { return }
        
        // Stop any current speech
        stopSpeaking()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Use provided voice or default
        if let voice = voice {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        currentUtterance = utterance
        currentText = text
        
        // Configure audio session: keep playAndRecord to avoid category thrash while hot mic is active
        NotificationCenter.default.post(name: Notification.Name("TTSDidStart"), object: nil)
        configureAudioSessionForPlayback()
        
        speechSynthesizer.speak(utterance)
    }
    
    func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterance = nil
        currentText = ""
        isSpeaking = false
    }
    
    func pauseSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.pauseSpeaking(at: .word)
        }
    }
    
    func continueSpeaking() {
        if speechSynthesizer.isPaused {
            speechSynthesizer.continueSpeaking()
        }
    }
    
    // Get available voices for language
    static func availableVoices(for language: String = "en-US") -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix(language.prefix(2))
        }
    }
    
    // Get default voice for language
    static func defaultVoice(for language: String = "en-US") -> AVSpeechSynthesisVoice? {
        return AVSpeechSynthesisVoice(language: language)
    }
    
    private func configureAudioSessionForPlayback() {
        let audioSession = AVAudioSession.sharedInstance()

        #if DEBUG
        AppLogger.verbose("🔧 [DEBUG] TTS configureAudioSessionForPlayback() - category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
        #endif

        do {
            // IMPORTANT: Don't reconfigure category/mode - SpeechService already set .playAndRecord + .videoRecording
            // That mode supports duplex (both recording AND playback), so TTS can play without changing modes.
            // Changing modes here causes "Session activation failed" errors after app sleep/resume.
            // Just ensure the session is active (idempotent operation).
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            #if DEBUG
            AppLogger.verbose("🔧 [DEBUG] TTS session activated successfully - category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
            #endif
        } catch {
            AppLogger.connection("⚠️ Failed to activate audio session for playback: \(error.localizedDescription)")
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension AVSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.currentText = ""
            self.currentUtterance = nil

            #if DEBUG
            let audioSession = AVAudioSession.sharedInstance()
            AppLogger.verbose("🔧 [DEBUG] TTS didFinish - BEFORE TTSDidFinish notification: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
            #endif

            NotificationCenter.default.post(name: Notification.Name("TTSDidFinish"), object: nil)
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.currentText = ""
            self.currentUtterance = nil

            #if DEBUG
            let audioSession = AVAudioSession.sharedInstance()
            AppLogger.verbose("🔧 [DEBUG] TTS didCancel - BEFORE TTSDidFinish notification: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
            #endif

            NotificationCenter.default.post(name: Notification.Name("TTSDidFinish"), object: nil)
        }
    }
}

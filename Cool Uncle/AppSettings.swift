import Foundation
import Security
import AVFoundation
import Combine

@MainActor
class AppSettings: ObservableObject {
    @Published var openAIAPIKey: String = ""
    @Published var misterIPAddress: String = "192.168.1.100"
    @Published var selectedVoiceIdentifier: String = ""
    @Published var avoidGamesDays: Int = 7  // Days to avoid recently played games in recommendations
    @Published var recommendConfirmMinutes: Int = 2  // Minutes before asking for confirmation (0 = never)
    @Published var hasSeenWakeModeSleepAlert: Bool = false  // Track if user has seen the wake mode battery warning
    
    // Debounce timers for performance optimization
    private var apiKeySaveTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    
    // Cached voices to avoid repeated enumeration
    private static var _cachedVoices: [AVSpeechSynthesisVoice]?
    @Published var voicesLoading: Bool = true
    @Published var loadedVoices: [AVSpeechSynthesisVoice] = []
    
    
    static let defaultAPIKey = "" // No longer needed - using Cloudflare proxy

    init() {
        loadSettings()
        setupDebouncedSaving()

        // Only load voices asynchronously (for menu settings)
        Task.detached(priority: .utility) { [weak self] in
            await self?.loadVoicesAsync()
        }
    }
    
    // MARK: - Debounced Saving Setup
    
    private func setupDebouncedSaving() {
        // Setup debounced saving for API key (Keychain operations) with throttling
        $openAIAPIKey
            .removeDuplicates()
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newKey in
                self?.debouncedSaveAPIKey(newKey)
            }
            .store(in: &cancellables)
        
        // Setup debounced saving for UserDefaults settings with throttling
        Publishers.CombineLatest4($misterIPAddress, $avoidGamesDays, $recommendConfirmMinutes, $hasSeenWakeModeSleepAlert)
            .removeDuplicates { old, new in
                old.0 == new.0 && old.1 == new.1 && old.2 == new.2 && old.3 == new.3
            }
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (ip, avoidDays, confirmMinutes, seenAlert) in
                self?.debouncedSaveSettings(ip: ip, avoidDays: avoidDays, confirmMinutes: confirmMinutes, seenAlert: seenAlert)
            }
            .store(in: &cancellables)
        
        // Voice settings save immediately (less frequent changes)
            
        $selectedVoiceIdentifier
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { newVoice in
                UserDefaults.standard.set(newVoice, forKey: "selectedVoiceIdentifier")
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private func debouncedSaveAPIKey(_ key: String) {
        // Cancel previous save task
        apiKeySaveTask?.cancel()
        
        // Start new debounced save task (1000ms delay for less frequent saves)
        apiKeySaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1000ms
            
            guard !Task.isCancelled else { return }
            
            // Move to background queue for Keychain operations
            await Task.detached { [weak self] in
                await self?.saveAPIKeyToKeychainSync(key)
                
                // Log performance for debugging
                await MainActor.run {
                    AppLogger.storage("API key saved to Keychain asynchronously")
                }
            }.value
        }
    }
    
    private func debouncedSaveSettings(ip: String, avoidDays: Int, confirmMinutes: Int, seenAlert: Bool) {
        // Cancel previous save task
        settingsSaveTask?.cancel()

        // Start new debounced save task (800ms delay for less frequent saves)
        settingsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000) // 800ms

            guard !Task.isCancelled else { return }

            // Save to UserDefaults on background queue with change detection
            await Task.detached {
                let startTime = CFAbsoluteTimeGetCurrent()
                var changeCount = 0

                // Only save if values actually changed
                if UserDefaults.standard.string(forKey: "misterIPAddress") != ip {
                    UserDefaults.standard.set(ip, forKey: "misterIPAddress")
                    changeCount += 1
                }
                if UserDefaults.standard.integer(forKey: "avoidGamesDays") != avoidDays {
                    UserDefaults.standard.set(avoidDays, forKey: "avoidGamesDays")
                    changeCount += 1
                }
                if UserDefaults.standard.integer(forKey: "recommendConfirmMinutes") != confirmMinutes {
                    UserDefaults.standard.set(confirmMinutes, forKey: "recommendConfirmMinutes")
                    changeCount += 1
                }
                if UserDefaults.standard.bool(forKey: "hasSeenWakeModeSleepAlert") != seenAlert {
                    UserDefaults.standard.set(seenAlert, forKey: "hasSeenWakeModeSleepAlert")
                    changeCount += 1
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                let finalChangeCount = changeCount

                // Log performance for debugging
                await MainActor.run {
                    AppLogger.storage("Settings saved to UserDefaults (\(finalChangeCount) changes, \(duration * 1000)ms)")
                }
            }.value
        }
    }
    
    private func loadSettings() {
        // Load API key from keychain
        openAIAPIKey = loadAPIKeyFromKeychain() ?? Self.defaultAPIKey

        // Load other settings from UserDefaults
        misterIPAddress = UserDefaults.standard.string(forKey: "misterIPAddress") ?? "192.168.1.100"
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier") ?? ""
        avoidGamesDays = UserDefaults.standard.integer(forKey: "avoidGamesDays") == 0 ? 7 : UserDefaults.standard.integer(forKey: "avoidGamesDays")  // Default to 7 if not set
        recommendConfirmMinutes = UserDefaults.standard.integer(forKey: "recommendConfirmMinutes") == 0 ? 2 : UserDefaults.standard.integer(forKey: "recommendConfirmMinutes")  // Default to 2 if not set
        hasSeenWakeModeSleepAlert = UserDefaults.standard.bool(forKey: "hasSeenWakeModeSleepAlert")  // Default to false if not set
    }

    private func loadVoicesAsync() async {
        let voices = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
                    voice.language.hasPrefix("en")
                }.sorted { voice1, voice2 in
                    // Premium/Enhanced voices first, then default voices
                    if voice1.quality != voice2.quality {
                        return voice1.quality.rawValue > voice2.quality.rawValue
                    }
                    return voice1.name < voice2.name
                }
                continuation.resume(returning: voices)
            }
        }

        // Update UI on main thread
        await MainActor.run {
            self.loadedVoices = voices
            self.voicesLoading = false
            Self._cachedVoices = voices
        }
    }
    
    private func saveAPIKeyToKeychainSync(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "openai-api-key",
            kSecValueData as String: data
        ]
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Delete existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        AppLogger.performance("Keychain operation took \(duration * 1000)ms (status: \(status))")
    }
    
    // Legacy method for immediate saves (used by resetToDefaults)
    private func saveAPIKeyToKeychain(_ key: String) {
        saveAPIKeyToKeychainSync(key)
    }
    
    private func loadAPIKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "openai-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return key
    }
    
    func resetToDefaults() {
        openAIAPIKey = Self.defaultAPIKey
        misterIPAddress = "192.168.1.100"
        selectedVoiceIdentifier = ""
        avoidGamesDays = 7
        recommendConfirmMinutes = 2
        hasSeenWakeModeSleepAlert = false
    }
    
    // Get selected voice or default to Aaron (Enhanced)
    var selectedVoice: AVSpeechSynthesisVoice? {
        if selectedVoiceIdentifier.isEmpty {
            // Find Aaron (Enhanced) or fallback to first enhanced/premium voice
            let aaron = Self.availableVoices.first { $0.name.contains("Aaron") && $0.quality == .enhanced }
            let bestQuality = Self.availableVoices.first { $0.quality == .enhanced || $0.quality == .premium }
            return aaron ?? bestQuality ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        return AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier)
    }
    
    // Get available voices for settings (uses cached voices or loads synchronously if needed)
    static var availableVoices: [AVSpeechSynthesisVoice] {
        if let cached = _cachedVoices {
            return cached
        }

        // Fallback: load synchronously if cache not ready (should be rare)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en")
        }.sorted { voice1, voice2 in
            // Premium/Enhanced voices first, then default voices
            if voice1.quality != voice2.quality {
                return voice1.quality.rawValue > voice2.quality.rawValue
            }
            return voice1.name < voice2.name
        }

        _cachedVoices = voices
        return voices
    }
    
    // Method to refresh voice cache if needed
    static func refreshVoiceCache() {
        _cachedVoices = nil
        _ = availableVoices // Trigger re-caching
    }
    
    // MARK: - Dynamic System Prompt
    
    
    
}

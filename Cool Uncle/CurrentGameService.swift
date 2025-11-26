import Foundation

/// Service to manage the currently running game state and cached launch commands
/// 
/// **Purpose**: Provides access to current game information for launching and display
/// - Tracks current game name, system, and launch command
/// - Enables re-launching the current game from anywhere in the app
/// - Updates game context for voice interactions

@MainActor
class CurrentGameService: ObservableObject {
    
    static let shared = CurrentGameService()
    
    // MARK: - Published Properties
    
    @Published var currentGameName: String?
    @Published var currentGameSystem: String?
    @Published var currentGameMediaPath: String?
    @Published var currentGameLaunchCommand: String?
    @Published var sessionStartTime: Date? // In-memory only - resets on app restart/disconnect
    
    private init() {
        loadCurrentGameState()
    }
    
    // MARK: - Current Game State Management
    
    /// Load current game state from UserDefaults (session timer stays nil - in-memory only)
    private func loadCurrentGameState() {
        currentGameName = UserDefaults.standard.string(forKey: "currentGameName")
        currentGameSystem = UserDefaults.standard.string(forKey: "currentGameSystem")
        currentGameMediaPath = UserDefaults.standard.string(forKey: "currentGameMediaPath")
        currentGameLaunchCommand = UserDefaults.standard.string(forKey: "currentGameLaunchCommand")
        
        // Note: sessionStartTime remains nil on app restart - session timer is in-memory only
    }
    
    /// Update current game state
    func updateCurrentGame(
        name: String,
        system: String?,
        mediaPath: String?,
        launchCommand: String?
    ) {
        currentGameName = name
        currentGameSystem = system
        currentGameMediaPath = mediaPath
        currentGameLaunchCommand = launchCommand
        sessionStartTime = Date() // In-memory session timer starts fresh
        
        // Persist game info to UserDefaults (but not session timer)
        UserDefaults.standard.set(name, forKey: "currentGameName")
        if let system = system {
            UserDefaults.standard.set(system, forKey: "currentGameSystem")
        }
        if let mediaPath = mediaPath {
            UserDefaults.standard.set(mediaPath, forKey: "currentGameMediaPath")
        }
        if let launchCommand = launchCommand {
            UserDefaults.standard.set(launchCommand, forKey: "currentGameLaunchCommand")
        }
        // Note: No longer persisting timestamp - session timer is in-memory only
        
        AppLogger.gameHistory("🎮 CurrentGameService: Updated to \(name) on \(system ?? "unknown")")
    }
    
    /// Clear current game state
    func clearCurrentGame() {
        currentGameName = nil
        currentGameSystem = nil
        currentGameMediaPath = nil
        currentGameLaunchCommand = nil
        sessionStartTime = nil
        
        UserDefaults.standard.removeObject(forKey: "currentGameName")
        UserDefaults.standard.removeObject(forKey: "currentGameSystem")
        UserDefaults.standard.removeObject(forKey: "currentGameMediaPath")
        UserDefaults.standard.removeObject(forKey: "currentGameLaunchCommand")
        
        AppLogger.gameHistory("🎮 CurrentGameService: Cleared current game state")
    }
    
    /// Clear session timer (for disconnect/reconnect scenarios)
    func clearSessionTimer() {
        sessionStartTime = nil
        AppLogger.gameHistory("🎮 CurrentGameService: Cleared session timer")
    }
    
    // MARK: - Convenience Properties
    
    /// Check if there's a current game with a launch command
    var hasLaunchableGame: Bool {
        return currentGameName != nil && currentGameLaunchCommand != nil
    }
    
    /// Get display string for current game
    var currentGameDisplayString: String {
        guard let name = currentGameName else { return "No game running" }
        
        if let system = currentGameSystem {
            return "\(name) (\(system))"
        } else {
            return name
        }
    }
    
    /// Get the media path for launching (without **launch: prefix)
    var launchPath: String? {
        return currentGameMediaPath
    }
    
    /// Get time since current session started
    var sessionDuration: String? {
        guard let startTime = sessionStartTime else { return nil }
        
        let interval = Date().timeIntervalSince(startTime)
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "Just started"
        }
    }
    
    /// Future feature: Get cumulative play time from MiSTer tokens.history
    var cumulativePlayTime: String? {
        // TODO: Implement by querying tokens.history API and calculating total session time
        // This would sum all successful game launch durations from MiSTer
        return nil // Stub for now
    }
    
    // MARK: - GameContextSnapshot Integration
    
    /// Create a GameContextSnapshot for AI prompts
    func createGameContextSnapshot(forUserMessage: String) -> GameContextSnapshot {
        // Calculate session duration in minutes from in-memory timer
        let sessionDurationMinutes: Int? = {
            guard let startTime = sessionStartTime else { return nil }
            let interval = Date().timeIntervalSince(startTime)
            return Int(interval / 60)
        }()
        
        return GameContextSnapshot(
            currentGame: currentGameName,
            currentSystem: currentGameSystem,
            sessionDurationMinutes: sessionDurationMinutes,
            forUserMessage: forUserMessage,
            lastLaunchCommand: currentGameLaunchCommand
        )
    }
}
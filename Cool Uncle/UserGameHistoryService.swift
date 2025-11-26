import Foundation

/// Manages persistent, user-centric gaming history across all sessions and networks
///
/// **Architecture**: This service stores the user's complete gaming timeline locally,
/// independent of network connections or app sessions. It provides the AI with rich
/// personal context about the user's gaming preferences and history.
///
/// **Key Benefits**:
/// - Gaming history survives app kills, network changes, and device switches
/// - Enables true personal assistant behavior: "You played Contra yesterday"
/// - Cross-location continuity: Works at home, friend's house, anywhere
/// - Long-term learning: Assistant gets better over time
/// - User privacy: All data stored locally on device
///
/// **Usage**:
/// ```swift
/// let historyService = UserGameHistoryService.shared
/// historyService.recordGameCommand(method: "launch", params: ["text": "Contra"])
/// let context = historyService.getGameContextSummary()
/// ```
@MainActor
class UserGameHistoryService: ObservableObject {
    
    static let shared = UserGameHistoryService()
    
    // MARK: - Configuration
    
    private let maxHistoryDays = 30        // Keep 30 days of gaming history
    private let maxCommands = 200          // Keep last 200 commands max
    private let storageKey = "userGameHistory"
    private let maxContextCommands = 20    // Commands to include in AI context
    
    // MARK: - Data Models
    
    /// Represents a user's game command for persistent storage
    struct GameCommand: Codable {
        let timestamp: Date
        let method: String
        let params: [String: AnyCodable]?
        let success: Bool?
        let response: String?
        let sessionInfo: String? // Optional context about the session
        
        init(timestamp: Date = Date(), method: String, params: [String: Any]? = nil, success: Bool? = nil, response: String? = nil, sessionInfo: String? = nil) {
            self.timestamp = timestamp
            self.method = method
            self.params = params?.mapValues(AnyCodable.init)
            self.success = success
            self.response = response
            self.sessionInfo = sessionInfo
        }
    }
    
    // MARK: - Core Recording
    
    /// Record a game command to the user's persistent history
    func recordGameCommand(method: String, params: [String: Any]? = nil, success: Bool? = nil, response: String? = nil) {
        let command = GameCommand(
            method: method,
            params: params,
            success: success,
            response: response,
            sessionInfo: getCurrentSessionInfo()
        )
        
        var history = loadFullHistory()
        history.append(command)
        
        // Trim history to keep within limits
        history = trimHistory(history)
        
        saveFullHistory(history)
        
        AppLogger.gameHistory("Recorded \(method) command (total: \(history.count) commands)")
    }
    
    // MARK: - Context Building for AI
    
    /// Get game context summary for AI conversations
    func getGameContextSummary(days: Int = 7, limit: Int = 20) -> String {
        let history = loadFullHistory()
        let recentCommands = getRecentCommands(from: history, days: days, limit: limit)
        
        if recentCommands.isEmpty {
            return "No recent gaming history available"
        }
        
        return formatGameContextForAI(recentCommands)
    }
    
    /// Get recently played game names to avoid in recommendations
    func getRecentlyPlayedGames(days: Int = 7) -> [String] {
        let history = loadFullHistory()
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        AppLogger.verbose("🎯 Avoid List Filter: days=\(days), cutoffDate=\(cutoffDate), totalHistory=\(history.count)")

        let recentLaunches = history
            .filter { $0.method == "launch" && $0.success == true && $0.timestamp >= cutoffDate }
            .compactMap { command -> String? in
                guard let params = command.params,
                      let text = params["text"]?.value as? String else { return nil }
                return extractGameNameFromPath(text)
            }

        let uniqueGames = Array(Set(recentLaunches))
        AppLogger.verbose("🎯 Avoid List Result: \(uniqueGames.count) unique games after filtering")

        return uniqueGames
    }
    
    /// Extract clean game name from launch path
    private func extractGameNameFromPath(_ path: String) -> String? {
        // Extract filename from path like "SNES/H-N/Legend of Zelda, The - A Link to the Past (USA).zip/..."
        let components = path.split(separator: "/")
        guard let filename = components.last else { return nil }
        
        // Remove file extension and clean up - comprehensive list for all MiSTer systems
        let cleanName = String(filename)
            // SNES extensions
            .replacingOccurrences(of: ".sfc", with: "")
            .replacingOccurrences(of: ".smc", with: "")
            // NES extensions
            .replacingOccurrences(of: ".nes", with: "")
            // Genesis/MegaDrive extensions
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: ".gen", with: "")
            .replacingOccurrences(of: ".bin", with: "")
            // Game Boy extensions
            .replacingOccurrences(of: ".gb", with: "")
            .replacingOccurrences(of: ".gbc", with: "")
            .replacingOccurrences(of: ".gba", with: "")
            // Nintendo 64 extensions
            .replacingOccurrences(of: ".n64", with: "")
            .replacingOccurrences(of: ".v64", with: "")
            .replacingOccurrences(of: ".z64", with: "")
            // PlayStation extensions
            .replacingOccurrences(of: ".cue", with: "")
            .replacingOccurrences(of: ".chd", with: "")
            .replacingOccurrences(of: ".iso", with: "")
            // Saturn extensions
            .replacingOccurrences(of: ".ccd", with: "")
            // Arcade extensions
            .replacingOccurrences(of: ".rom", with: "")
            // Atari 2600 extensions
            .replacingOccurrences(of: ".a26", with: "")
            .replacingOccurrences(of: ".bin", with: "")
            // C64 extensions
            .replacingOccurrences(of: ".d64", with: "")
            .replacingOccurrences(of: ".t64", with: "")
            .replacingOccurrences(of: ".prg", with: "")
            .replacingOccurrences(of: ".tap", with: "")
            .replacingOccurrences(of: ".crt", with: "")
            // TurboGrafx16 extensions
            .replacingOccurrences(of: ".pce", with: "")
            .replacingOccurrences(of: ".sgx", with: "")
            // NeoGeo extensions
            .replacingOccurrences(of: ".neo", with: "")
            // Master System extensions
            .replacingOccurrences(of: ".sms", with: "")
            // Sega 32X extensions
            .replacingOccurrences(of: ".32x", with: "")
            // MegaCD extensions
            .replacingOccurrences(of: ".mds", with: "")
            // MSX extensions
            .replacingOccurrences(of: ".dsk", with: "")
            .replacingOccurrences(of: ".cas", with: "")
            // DOS extensions
            .replacingOccurrences(of: ".img", with: "")
            .replacingOccurrences(of: ".ima", with: "")
            .replacingOccurrences(of: ".vhd", with: "")
            // Amiga extensions
            .replacingOccurrences(of: ".adf", with: "")
            .replacingOccurrences(of: ".hdf", with: "")
            .replacingOccurrences(of: ".lha", with: "")
            // ZX Spectrum Next extensions
            .replacingOccurrences(of: ".nex", with: "")
            .replacingOccurrences(of: ".sna", with: "")
            .replacingOccurrences(of: ".tzx", with: "")
            // Common archive extensions
            .replacingOccurrences(of: ".zip", with: "")
            .replacingOccurrences(of: ".7z", with: "")
            .replacingOccurrences(of: ".rar", with: "")
        
        return cleanName
    }
    
    /// Get detailed gaming statistics for settings/debug
    func getGameStatistics() -> GameStatistics {
        let history = loadFullHistory()
        return calculateStatistics(from: history)
    }
    
    // MARK: - User Management
    
    /// Clear the user's complete gaming history (privacy/reset option)
    func clearUserHistory() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        AppLogger.gameHistory("Cleared all user gaming history")
    }
    
    /// Get count of stored commands for UI display
    func getHistoryCount() -> Int {
        return loadFullHistory().count
    }
    
    /// Get date range of stored history
    func getHistoryDateRange() -> (oldest: Date?, newest: Date?) {
        let history = loadFullHistory()
        guard !history.isEmpty else { return (nil, nil) }
        
        let sorted = history.sorted { $0.timestamp < $1.timestamp }
        return (oldest: sorted.first?.timestamp, newest: sorted.last?.timestamp)
    }
    
    // MARK: - Private Implementation
    
    /// Load complete user gaming history from storage
    private func loadFullHistory() -> [GameCommand] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([GameCommand].self, from: data)
        } catch {
            AppLogger.verbose("UserGameHistory: Failed to load history: \(error)")
            return []
        }
    }
    
    /// Save complete user gaming history to storage
    private func saveFullHistory(_ history: [GameCommand]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            AppLogger.verbose("UserGameHistory: Failed to save history: \(error)")
        }
    }
    
    /// Trim history to stay within configured limits
    private func trimHistory(_ history: [GameCommand]) -> [GameCommand] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date()) ?? Date.distantPast
        
        // Filter by date and limit by count
        let recent = history
            .filter { $0.timestamp >= cutoffDate }
            .suffix(maxCommands)
        
        return Array(recent)
    }
    
    /// Get recent commands within specified constraints
    private func getRecentCommands(from history: [GameCommand], days: Int, limit: Int) -> [GameCommand] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        
        return history
            .filter { $0.timestamp >= cutoffDate }
            .suffix(limit)
            .sorted { $0.timestamp < $1.timestamp }
    }
    
    /// Format game context for AI consumption
    private func formatGameContextForAI(_ commands: [GameCommand]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        
        var context = "PERSONAL GAMING HISTORY (Last \(commands.count) commands):\n"
        
        for command in commands {
            let timestamp = formatter.string(from: command.timestamp)
            let status = command.success == true ? "✅" : (command.success == false ? "❌" : "⏳")
            
            var line = "- \(timestamp): \(command.method)"
            
            // Add meaningful parameters
            if let params = command.params {
                if let query = params["query"]?.value as? String {
                    line += " query=\"\(query)\""
                }
                if let systems = params["systems"]?.value as? [String], !systems.isEmpty {
                    line += " systems=\(systems)"
                }
                if let text = params["text"]?.value as? String {
                    let shortText = text.count > 30 ? String(text.prefix(30)) + "..." : text
                    line += " \"\(shortText)\""
                }
            }
            
            line += " \(status)"
            
            if command.success == false, let response = command.response {
                line += " (\(response))"
            }
            
            context += "\n\(line)"
        }
        
        // Add insights about user preferences
        let insights = generateUserInsights(from: commands)
        if !insights.isEmpty {
            context += "\n\nUSER PREFERENCES:\n\(insights)"
        }
        
        context += "\n\nNote: This is the user's personal gaming history across all sessions and locations."
        
        return context
    }
    
    /// Generate insights about user gaming preferences
    private func generateUserInsights(from commands: [GameCommand]) -> String {
        var insights: [String] = []
        
        // Analyze launched games
        let launchCommands = commands.filter { $0.method == "launch" && $0.success == true }
        if !launchCommands.isEmpty {
            let gameCount = launchCommands.count
            insights.append("- Launched \(gameCount) game\(gameCount == 1 ? "" : "s") recently")
        }
        
        // Analyze search patterns
        let searchCommands = commands.filter { $0.method == "media.search" }
        if !searchCommands.isEmpty {
            let searchTerms = extractSearchTerms(from: searchCommands)
            if !searchTerms.isEmpty {
                insights.append("- Recently searched for: \(searchTerms.joined(separator: ", "))")
            }
        }
        
        // Analyze system preferences
        let systemPreferences = extractSystemPreferences(from: commands)
        if !systemPreferences.isEmpty {
            insights.append("- Prefers systems: \(systemPreferences.joined(separator: ", "))")
        }
        
        // Analyze activity patterns
        let daysSinceLastActivity = daysSince(commands.last?.timestamp)
        if let days = daysSinceLastActivity {
            if days == 0 {
                insights.append("- Active today")
            } else if days == 1 {
                insights.append("- Last played yesterday")
            } else if days <= 7 {
                insights.append("- Last played \(days) days ago")
            }
        }
        
        return insights.joined(separator: "\n")
    }
    
    /// Extract search terms from search commands
    private func extractSearchTerms(from commands: [GameCommand]) -> [String] {
        let terms = commands.compactMap { command -> String? in
            guard let params = command.params,
                  let query = params["query"]?.value as? String,
                  !query.isEmpty else { return nil }
            return query
        }
        
        // Return unique terms, limited to avoid clutter
        return Array(Set(terms)).prefix(5).map { $0 }
    }
    
    /// Extract system preferences from commands
    private func extractSystemPreferences(from commands: [GameCommand]) -> [String] {
        var systemCounts: [String: Int] = [:]
        
        for command in commands {
            if let params = command.params,
               let systems = params["systems"]?.value as? [String] {
                for system in systems {
                    systemCounts[system, default: 0] += 1
                }
            }
        }
        
        // Return top 3 systems by usage
        return systemCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
    }
    
    /// Calculate days since a given date
    private func daysSince(_ date: Date?) -> Int? {
        guard let date = date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }
    
    /// Get current session info for context
    private func getCurrentSessionInfo() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Session: \(formatter.string(from: Date()))"
    }
    
    /// Calculate comprehensive statistics
    private func calculateStatistics(from history: [GameCommand]) -> GameStatistics {
        let totalCommands = history.count
        let successfulCommands = history.filter { $0.success == true }.count
        let failedCommands = history.filter { $0.success == false }.count
        
        let launchCount = history.filter { $0.method == "launch" }.count
        let searchCount = history.filter { $0.method == "media.search" }.count
        let stopCount = history.filter { $0.method == "stop" }.count
        
        let dateRange = getHistoryDateRange()
        
        return GameStatistics(
            totalCommands: totalCommands,
            successfulCommands: successfulCommands,
            failedCommands: failedCommands,
            launchCount: launchCount,
            searchCount: searchCount,
            stopCount: stopCount,
            oldestEntry: dateRange.oldest,
            newestEntry: dateRange.newest
        )
    }
}

// MARK: - Supporting Types

/// Statistics about user's gaming history
struct GameStatistics {
    let totalCommands: Int
    let successfulCommands: Int
    let failedCommands: Int
    let launchCount: Int
    let searchCount: Int
    let stopCount: Int
    let oldestEntry: Date?
    let newestEntry: Date?
    
    var successRate: Double {
        guard totalCommands > 0 else { return 0 }
        return Double(successfulCommands) / Double(totalCommands)
    }
}
import Foundation

/// Manages user game preferences with multiple categorized lists
///
/// **Architecture**: Scalable preference system that supports multiple game lists
/// while maintaining separation between input methods and storage layer.
///
/// **Categories**:
/// - 🎮 Played: Permanent launch history - games launched OR user said "I've already played it" (never removed by sentiment analysis)
/// - 👎 Disliked: Games user explicitly rejected or said they don't like
/// - ⭐ Want to Play: Games user expressed interest in trying
/// - ❤️ Favorites: Games user loved or highly rated
///
/// **Launch History Behavior**: The "Played" category functions as a permanent launch history.
/// Games can be categorized into disliked/wantToPlay/favorites while remaining in the played list.
///
/// **Key Benefits**:
/// - Storage layer remains unchanged when adding new input methods
/// - Pluggable input strategies (launch commands, AI sentiment, manual)
/// - Future-proof for database migration (Core Data, SQLite)
/// - Cross-session persistence with privacy-first local storage
///
/// **Usage**:
/// ```swift
/// let service = GamePreferenceService.shared
/// service.recordGamePreference("Contra", category: .played, source: .launchCommand)
/// let playedGames = service.getGames(in: .played)
/// ```
@MainActor
class GamePreferenceService: ObservableObject {
    
    static let shared = GamePreferenceService()
    
    // MARK: - Configuration
    
    private let maxHistoryDays = 90        // Keep 90 days of preferences
    private let maxGamesPerCategory = 500  // Limit per category
    private let storageKey = "gamePreferences"
    
    // MARK: - Data Models
    
    /// Game preference categories
    enum PreferenceCategory: String, CaseIterable, Codable {
        case played = "played"
        case disliked = "disliked" 
        case wantToPlay = "wantToPlay"
        case favorites = "favorites"
        
        var displayName: String {
            switch self {
            case .played: return "🎮 Played Games"
            case .disliked: return "👎 Disliked Games"
            case .wantToPlay: return "⭐ Want to Play"
            case .favorites: return "❤️ Favorites"
            }
        }
        
        var emoji: String {
            switch self {
            case .played: return "🎮"
            case .disliked: return "👎"
            case .wantToPlay: return "⭐"
            case .favorites: return "❤️"
            }
        }
    }
    
    /// Source of preference input (for analytics and debugging)
    enum PreferenceSource: String, Codable {
        case launchCommand = "launch"
        case aiSentiment = "ai"
        case manual = "manual"
        case conversation = "conversation"
    }
    
    /// Individual game preference record
    struct GamePreference: Codable, Identifiable {
        let id: UUID
        let gameName: String
        let category: PreferenceCategory
        let source: PreferenceSource
        let timestamp: Date
        let context: String? // Optional context (e.g., system, reason)
        let launchCommand: String? // Cached launch command for re-launch
        
        init(gameName: String, category: PreferenceCategory, source: PreferenceSource, context: String? = nil, launchCommand: String? = nil) {
            self.id = UUID()
            self.gameName = gameName
            self.category = category
            self.source = source
            self.timestamp = Date()
            self.context = context
            self.launchCommand = launchCommand
        }
        
        // Let Swift automatically handle Codable - the optional launchCommand field 
        // will be handled gracefully for backward compatibility
    }
    
    /// Container for all game preferences
    struct GamePreferenceData: Codable {
        private var preferences: [GamePreference] = []
        
        mutating func addPreference(_ preference: GamePreference) {
            // Remove existing preference for same game in same category to avoid duplicates
            preferences.removeAll { $0.gameName.lowercased() == preference.gameName.lowercased() && $0.category == preference.category }
            preferences.append(preference)
        }
        
        func getPreferences(in category: PreferenceCategory) -> [GamePreference] {
            return preferences.filter { $0.category == category }.sorted { $0.timestamp > $1.timestamp }
        }
        
        func getAllPreferences() -> [GamePreference] {
            return preferences.sorted { $0.timestamp > $1.timestamp }
        }
        
        func hasPreference(gameName: String, in category: PreferenceCategory) -> Bool {
            return preferences.contains { $0.gameName.lowercased() == gameName.lowercased() && $0.category == category }
        }
        
        func getPreference(for gameName: String, in category: PreferenceCategory) -> GamePreference? {
            return preferences.first { $0.gameName.lowercased() == gameName.lowercased() && $0.category == category }
        }
        
        mutating func removePreference(gameName: String, from category: PreferenceCategory) {
            preferences.removeAll { $0.gameName.lowercased() == gameName.lowercased() && $0.category == category }
        }
        
        mutating func movePreference(gameName: String, from oldCategory: PreferenceCategory, to newCategory: PreferenceCategory, source: PreferenceSource) {
            // Find existing preference to preserve launch command and other data
            let existingPreference = preferences.first { $0.gameName.lowercased() == gameName.lowercased() && $0.category == oldCategory }
            
            // Move game from old category to new category, preserving launch command
            
            removePreference(gameName: gameName, from: oldCategory)
            
            // Create new preference preserving launch command and context
            let newPreference = GamePreference(
                gameName: gameName, 
                category: newCategory, 
                source: source, 
                context: existingPreference?.context,
                launchCommand: existingPreference?.launchCommand
            )
            
            // New preference created with preserved launch command
            
            addPreference(newPreference)
        }
        
        var count: Int { preferences.count }
    }
    
    // MARK: - Core Recording Methods
    
    /// Record a game preference with automatic duplicate handling
    func recordGamePreference(_ gameName: String, category: PreferenceCategory, source: PreferenceSource, context: String? = nil) {
        let preference = GamePreference(gameName: gameName, category: category, source: source, context: context)
        
        var data = loadPreferenceData()
        data.addPreference(preference)
        
        // Trim data to stay within limits
        data = trimPreferenceData(data)
        
        savePreferenceData(data)
        
        AppLogger.gameHistory("Recorded \(category.emoji) \(gameName) (\(source.rawValue))")
    }
    
    /// Record successful game launch (from command execution)
    func recordGameLaunch(_ gameName: String, system: String? = nil, launchCommand: String? = nil) {
        let context = system != nil ? "System: \(system!)" : nil

        // Create preference with launch command if provided
        let preference = GamePreference(
            gameName: gameName,
            category: .played,
            source: .launchCommand,
            context: context,
            launchCommand: launchCommand
        )

        var data = loadPreferenceData()
        data.addPreference(preference)

        // Trim data to stay within limits
        data = trimPreferenceData(data)

        savePreferenceData(data)

        AppLogger.gameHistory("Recorded 🎮 \(gameName) (launchCommand) with launch command: \(launchCommand != nil ? "Yes" : "No")")
    }
    
    /// Update launch command for an existing game preference with intelligent deduplication
    func updateLaunchCommand(_ gameName: String, launchCommand: String) {
        AppLogger.gameHistory("🔗 updateLaunchCommand called for: '\(gameName)'")
        var data = loadPreferenceData()
        var updated = false
        
        // Check for existing launch command first - if we already have one for this game, skip update
        let existingWithLaunchCommand = data.getAllPreferences().first { preference in
            preference.gameName.lowercased() == gameName.lowercased() && preference.launchCommand != nil
        }
        
        if let existing = existingWithLaunchCommand {
            AppLogger.gameHistory("🔗 ⚠️ Launch command already exists for '\(gameName)' - skipping duplicate (existing: '\(existing.gameName)')")
            AppLogger.gameHistory("🔗 Existing command length: \(existing.launchCommand!.count)")
            return
        }
        
        // Find the game in any category and update its launch command
        for category in PreferenceCategory.allCases {
            if let existingPreference = data.getPreference(for: gameName, in: category) {
                AppLogger.gameHistory("🔗 Found existing preference for '\(gameName)' in \(category.displayName)")
                
                // Only update if it doesn't already have a launch command
                if existingPreference.launchCommand == nil {
                    // Remove old preference
                    data.removePreference(gameName: gameName, from: category)
                    
                    // Add new preference with launch command
                    let updatedPreference = GamePreference(
                        gameName: existingPreference.gameName,
                        category: existingPreference.category,
                        source: existingPreference.source,
                        context: existingPreference.context,
                        launchCommand: launchCommand
                    )
                    data.addPreference(updatedPreference)
                    updated = true
                    
                    AppLogger.gameHistory("🔗 Updated launch command for \(gameName) in \(category.displayName)")
                    // Launch command successfully preserved
                } else {
                    AppLogger.gameHistory("🔗 ⚠️ Preference already has launch command - skipping duplicate update")
                    updated = true // Mark as updated to prevent creating new entry
                }
                break
            }
        }
        
        // If game not found in preferences but we have a launch command, add it to played
        if !updated {
            AppLogger.gameHistory("🔗 No existing preference found for '\(gameName)', creating new one")
            let newPreference = GamePreference(
                gameName: gameName,
                category: .played,
                source: .launchCommand,
                context: "Launch command added",
                launchCommand: launchCommand
            )
            data.addPreference(newPreference)
            AppLogger.gameHistory("🔗 Added new game with launch command: \(gameName)")
        }
        
        // Always save when changes are made (both updates and new entries)
        savePreferenceData(data)
        AppLogger.gameHistory("🔗 Launch command update completed for: '\(gameName)'")
    }
    
    /// Record game preference from AI conversation analysis
    func recordGameFromConversation(_ gameName: String, category: PreferenceCategory, reason: String? = nil) {
        var data = loadPreferenceData()
        
        // Special handling for "played" category - it should function as permanent launch history
        if category == .played {
            // Always preserve "played" status - just add if not already there
            if !data.hasPreference(gameName: gameName, in: .played) {
                recordGamePreference(gameName, category: .played, source: .aiSentiment, context: reason)
            }
            return
        }
        
        // For other categories (disliked, wantToPlay, favorites), handle overlays on launch history
        // Check if game exists in non-played categories and move between them
        let nonPlayedCategories = PreferenceCategory.allCases.filter { $0 != .played }
        
        for existingCategory in nonPlayedCategories {
            if existingCategory != category && data.hasPreference(gameName: gameName, in: existingCategory) {
                AppLogger.gameHistory("🔄 Moving '\(gameName)' from \(existingCategory) to \(category) (preserving launch history)")
                data.movePreference(gameName: gameName, from: existingCategory, to: category, source: .aiSentiment)
                savePreferenceData(data)
                AppLogger.gameHistory("Moved \(gameName): \(existingCategory.emoji) → \(category.emoji)")
                return
            }
        }
        
        // If not found in other non-played categories, check if it exists in "played" category
        // and copy that preference (with launch command) to preserve all existing data
        if let playedPreference = data.getPreference(for: gameName, in: .played) {
            AppLogger.gameHistory("🔄 Copying '\(gameName)' from played to \(category) (preserving launch command)")
            let copiedPreference = GamePreference(
                gameName: playedPreference.gameName,
                category: category,
                source: .aiSentiment,
                context: reason,
                launchCommand: playedPreference.launchCommand
            )
            data.addPreference(copiedPreference)
            savePreferenceData(data)
            AppLogger.gameHistory("Copied \(gameName): 🎮 → \(category.emoji) (launch command preserved)")
        } else {
            // If not found anywhere, add as new preference
            // Note: This preserves any existing "played" entry
            recordGamePreference(gameName, category: category, source: .aiSentiment, context: reason)
        }
    }
    
    /// Manually record game preference (from UI interaction)
    func recordGameManually(_ gameName: String, category: PreferenceCategory) {
        recordGamePreference(gameName, category: category, source: .manual)
    }
    
    // MARK: - Query Methods
    
    /// Get all games in a specific category
    func getGames(in category: PreferenceCategory) -> [GamePreference] {
        let data = loadPreferenceData()
        let games = data.getPreferences(in: category)
        
        // Debug: Log what games are being returned to the UI
        AppLogger.gameHistory("🔍 UI QUERY: getGames(\(category)) returning \(games.count) games:")
        for (index, game) in games.enumerated() {
            let hasLaunchCommand = game.launchCommand != nil
            let commandInfo = hasLaunchCommand ? "YES (\(game.launchCommand!.count) chars)" : "NO"
            AppLogger.gameHistory("   \(index + 1). '\(game.gameName)' - Launch command: \(commandInfo)")
        }
        
        return games
    }
    
    /// Check if a game exists in a specific category
    func hasGame(_ gameName: String, in category: PreferenceCategory) -> Bool {
        let data = loadPreferenceData()
        return data.hasPreference(gameName: gameName, in: category)
    }
    
    /// Get all game names in a category (simplified for AI context)
    func getGameNames(in category: PreferenceCategory) -> [String] {
        return getGames(in: category).map { $0.gameName }
    }
    
    /// Get comprehensive AI context about user preferences
    func getPreferenceContextForAI() -> String {
        let data = loadPreferenceData()
        var context: [String] = []

        for category in PreferenceCategory.allCases {
            // Skip "Played" category - avoid list handles this better
            if category == .played {
                continue
            }

            let games = data.getPreferences(in: category)
            if !games.isEmpty {
                // Show ALL favorites (no truncation), limit others to 10
                let limit = category == .favorites ? games.count : 10
                let gameNames = games.prefix(limit).map { $0.gameName }.joined(separator: ", ")
                context.append("\(category.displayName): \(gameNames)")
                if games.count > limit {
                    context.append("  ... and \(games.count - limit) more")
                }
            }
        }

        if context.isEmpty {
            return "No game preferences recorded yet"
        }

        return context.joined(separator: "\n")
    }
    
    /// Get statistics for all categories
    func getPreferenceStatistics() -> [PreferenceCategory: Int] {
        let data = loadPreferenceData()
        var stats: [PreferenceCategory: Int] = [:]
        
        for category in PreferenceCategory.allCases {
            stats[category] = data.getPreferences(in: category).count
        }
        
        return stats
    }
    
    // MARK: - Management Methods
    
    /// Move a game from one category to another
    func moveGame(_ gameName: String, from oldCategory: PreferenceCategory, to newCategory: PreferenceCategory) {
        var data = loadPreferenceData()
        
        // Special handling: never allow removal from "played" category (it's permanent launch history)
        if oldCategory == .played && newCategory != .played {
            // Instead of moving from played, just add to the new category (played remains)
            if !data.hasPreference(gameName: gameName, in: newCategory) {
                recordGamePreference(gameName, category: newCategory, source: .manual)
            }
            AppLogger.gameHistory("Added \(gameName) to \(newCategory.emoji) (keeping in \(oldCategory.emoji))")
        } else {
            // Normal move for non-played categories
            data.movePreference(gameName: gameName, from: oldCategory, to: newCategory, source: .manual)
            savePreferenceData(data)
            AppLogger.gameHistory("Moved \(gameName): \(oldCategory.emoji) → \(newCategory.emoji)")
        }
    }
    
    /// Remove a game from a specific category
    func removeGame(_ gameName: String, from category: PreferenceCategory) {
        var data = loadPreferenceData()
        data.removePreference(gameName: gameName, from: category)
        savePreferenceData(data)
        
        AppLogger.gameHistory("Removed \(gameName) from \(category.displayName)")
    }
    
    /// Clear all preferences (privacy/reset option)
    func clearAllPreferences() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        AppLogger.gameHistory("Cleared all game preferences")
    }
    
    /// Clear specific category
    func clearCategory(_ category: PreferenceCategory) {
        var data = loadPreferenceData()
        let games = data.getPreferences(in: category)
        for game in games {
            data.removePreference(gameName: game.gameName, from: category)
        }
        savePreferenceData(data)
        
        AppLogger.gameHistory("Cleared \(category.displayName) (\(games.count) games)")
    }
    
    // MARK: - Private Storage Implementation
    
    private func loadPreferenceData() -> GamePreferenceData {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            AppLogger.verbose("GamePreferenceService: No preference data found in UserDefaults")
            return GamePreferenceData()
        }
        
        // Successfully loaded preference data
        
        do {
            let decoder = JSONDecoder()
            // Use default date strategy for better compatibility
            let loadedData = try decoder.decode(GamePreferenceData.self, from: data)
            
            return loadedData
        } catch {
            AppLogger.verbose("GamePreferenceService: Failed to load preferences: \(error)")
            return GamePreferenceData()
        }
    }
    
    private func savePreferenceData(_ data: GamePreferenceData) {
        do {
            let encoder = JSONEncoder()
            // Use default date strategy to match decoder
            let encodedData = try encoder.encode(data)
            UserDefaults.standard.set(encodedData, forKey: storageKey)
            
            // Force immediate synchronization to prevent race conditions
            UserDefaults.standard.synchronize()
            
            // Successfully saved preferences to UserDefaults
        } catch {
            AppLogger.standard("❌ GamePreferenceService: Failed to save preferences: \(error)")
        }
    }
    
    private func trimPreferenceData(_ data: GamePreferenceData) -> GamePreferenceData {
        var trimmedData = GamePreferenceData()
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date()) ?? Date.distantPast
        
        // Trim each category to stay within limits
        for category in PreferenceCategory.allCases {
            let categoryPreferences = data.getPreferences(in: category)
                .filter { $0.timestamp >= cutoffDate }
                .prefix(maxGamesPerCategory)
            
            for preference in categoryPreferences {
                trimmedData.addPreference(preference)
            }
        }
        
        return trimmedData
    }
    
    /// Restore games with launch commands to the played category (data migration helper)
    func restorePlayedGamesWithLaunchCommands() {
        var data = loadPreferenceData()
        var restoredCount = 0
        
        // Find all games with launch commands that aren't in the played category
        let allPreferences = data.getAllPreferences()
        for preference in allPreferences {
            if let launchCommand = preference.launchCommand, 
               preference.category != .played,
               !data.hasPreference(gameName: preference.gameName, in: .played) {
                
                AppLogger.gameHistory("🔄 Restoring '\(preference.gameName)' to played category (has launch command)")
                
                // Add to played category while preserving the launch command
                let playedPreference = GamePreference(
                    gameName: preference.gameName,
                    category: .played,
                    source: .launchCommand,
                    context: "Restored - had launch command",
                    launchCommand: launchCommand
                )
                data.addPreference(playedPreference)
                restoredCount += 1
            }
        }
        
        if restoredCount > 0 {
            savePreferenceData(data)
            AppLogger.gameHistory("🔄 Restored \(restoredCount) games to played category")
        }
    }
    
    // MARK: - Debug and Export
    
    /// Get detailed breakdown for debugging/settings
    func getDetailedBreakdown() -> String {
        let data = loadPreferenceData()
        var breakdown: [String] = []
        
        breakdown.append("GAME PREFERENCE BREAKDOWN:")
        breakdown.append("Total entries: \(data.count)")
        breakdown.append("")
        
        for category in PreferenceCategory.allCases {
            let games = data.getPreferences(in: category)
            breakdown.append("\(category.displayName): \(games.count) games")
            
            for game in games.prefix(5) {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                let date = formatter.string(from: game.timestamp)
                breakdown.append("  • \(game.gameName) (\(date), \(game.source.rawValue))")
            }
            
            if games.count > 5 {
                breakdown.append("  ... and \(games.count - 5) more")
            }
            breakdown.append("")
        }
        
        return breakdown.joined(separator: "\n")
    }
}

// MARK: - Integration with Existing Systems

extension GamePreferenceService {
    /// Integration point for UserGameHistoryService migration
    func migrateFromUserGameHistory() {
        // This method would migrate existing UserGameHistoryService data
        // to the new preference system if needed
        AppLogger.gameHistory("Game preference migration not yet implemented")
    }
}
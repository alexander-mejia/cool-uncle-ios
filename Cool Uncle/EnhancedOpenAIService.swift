import Foundation
import os.log

/// Timing configuration for command execution delays
private enum TimingConfig {
    // Check environment variable first, then use defaults
    static let commandExecutionDelay: UInt64 = {
        if let envValue = ProcessInfo.processInfo.environment["COMMAND_DELAY_MS"],
           let ms = UInt64(envValue) {
            return ms * 1_000_000 // Convert ms to nanoseconds
        }
        return 0 // Default: no artificial wait (was 30ms)
    }()
    
    static let searchExecutionDelay: UInt64 = {
        if let envValue = ProcessInfo.processInfo.environment["SEARCH_DELAY_MS"],
           let ms = UInt64(envValue) {
            return ms * 1_000_000
        }
        return 0 // Default: no artificial wait (was 30ms)
    }()
    
    static let fallbackResponseDelay: UInt64 = {
        if let envValue = ProcessInfo.processInfo.environment["FALLBACK_DELAY_MS"],
           let ms = UInt64(envValue) {
            return ms * 1_000_000
        }
        return 10_000_000_000 // Default: 10 seconds (keep high for error handling)
    }()
    
    // Helper to get delay in milliseconds for logging
    static func delayInMs(_ nanoseconds: UInt64) -> Int {
        return Int(nanoseconds / 1_000_000)
    }
}

/// Immutable snapshot of game context when user spoke - prevents race conditions
struct GameContextSnapshot: Codable {
    let currentGame: String?
    let currentSystem: String?
    let sessionDurationMinutes: Int? // Duration since current game was launched
    let capturedAt: Date
    let forUserMessage: String
    let lastLaunchCommand: String? // The JSON command used to launch the current game

    init(currentGame: String?, currentSystem: String?, sessionDurationMinutes: Int? = nil, forUserMessage: String, lastLaunchCommand: String? = nil) {
        self.currentGame = currentGame
        self.currentSystem = currentSystem
        self.sessionDurationMinutes = sessionDurationMinutes
        self.capturedAt = Date()
        self.forUserMessage = forUserMessage
        self.lastLaunchCommand = lastLaunchCommand
    }

    /// Get the game name for sentiment analysis, defaulting to "unknown game" if nil
    var sentimentTargetGame: String {
        return currentGame ?? "unknown game"
    }
}

/// Context object that gets enriched and passed between the 3 calls
struct ThreeCallContext {
    // Input context
    var userMessage: String // Made mutable for retry logic
    var conversationHistory: [ChatMessage]
    let gameHistory: String
    let gamePreferences: String
    let availableSystems: [String]
    var gameContextSnapshot: GameContextSnapshot
    
    var originalSearchQuery: String? // The original game/query that failed
    var previousFailureReason: String? // Why the previous attempt failed
    var rejectedGames: [String] = [] // Games that failed Step 4 validation (in avoid list)
    
    // Call A results (JSON command generation)
    var jsonCommand: String?
    var actionType: String? // "search", "launch", "random", etc.
    var actionContext: String? // What the action is about
    var needsSalesPitch: Bool = false // Flag for Call B to provide sales pitch when user asks about pending recommendation
    var recommendationSource: String? // "search", "yolo", "cached" - tracks how recommendation was obtained
    
    // Call B results (Cool Uncle speech)
    var coolUncleResponse: String?
    var responseTheme: String? // The main theme/emotion of the response
    var coolUncleHumorSet: Bool = false // Flag when Cool Uncle humor is set directly (bypasses Call B)
    
    // Call C results (Sentiment analysis - processed by SentimentAnalysisService.swift)
    var sentimentAnalysis: String?
    var preferenceUpdates: String?
    
    // Optimized launch_specific fields
    var targetGame: String? // The exact game name user wants to launch
    var searchTermsUsed: [String]? // The 3 search terms generated for parallel search
    var lastSearchSystem: String? // System from previous search (for follow-up requests like "play that game")
}

// MARK: - Model Configuration Override System

/// Configuration for OpenAI model parameters with optional override support
/// Allows individual prompts to declare specific model requirements
struct ModelConfig {
    let model: String?
    let temperature: Double?
    let maxTokens: Int?

    // MARK: - Default Configurations

    /// Default configuration for Call A (JSON command generation)
    static let defaultCallA = ModelConfig(
        model: "gpt-4o",
        temperature: 0.2,
        maxTokens: 200
    )

    /// Default configuration for Call B (Cool Uncle speech generation)
    static let defaultCallB = ModelConfig(
        model: "gpt-4o-mini",
        temperature: 0.8,
        maxTokens: 4096
    )

    // NOTE: Call C configuration moved to SentimentAnalysisService.swift

    // MARK: - Override Presets

    /// High-accuracy informational responses (factual questions)
    /// Uses gpt-4o for better instruction following and reduced hallucinations
    static func callBInformational() -> ModelConfig {
        ModelConfig(model: "gpt-4o", temperature: 0.6, maxTokens: 4096)
    }

    /// Brief utility command responses (save/load/menu)
    /// Lower temperature and token limit for concise responses
    static func callBUtility() -> ModelConfig {
        ModelConfig(model: "gpt-4o-mini", temperature: 0.6, maxTokens: 150)
    }

    /// Game selection accuracy for recommendations
    /// Lower temperature for more deterministic game choices
    static func callAGameSelection() -> ModelConfig {
        ModelConfig(model: "gpt-4o", temperature: 0.15, maxTokens: 500)
    }

    // MARK: - Helper Methods

    /// Apply this config to request body, using defaults as fallback
    func apply(to requestBody: inout [String: Any], defaults: ModelConfig) {
        requestBody["model"] = model ?? defaults.model ?? "gpt-4o-mini"
        requestBody["temperature"] = temperature ?? defaults.temperature ?? 0.8
        requestBody["max_tokens"] = maxTokens ?? defaults.maxTokens ?? 2000
    }

    /// Description for logging (shows which values are overridden)
    var description: String {
        let modelStr = model ?? "default"
        let tempStr = temperature.map { String(format: "%.2f", $0) } ?? "default"
        let tokensStr = maxTokens.map { "\($0)" } ?? "default"
        return "model=\(modelStr), temp=\(tempStr), tokens=\(tokensStr)"
    }
}

// MARK: - Optimized Search Architecture

/// Strategy pattern for different action types using optimized search
protocol OptimizedSearchStrategy {
    /// Generate search terms prompt for this action type
    func buildSearchTermsPrompt(context: ThreeCallContext) -> String

    /// Build enriched user message with context and preferences
    func buildEnrichedUserMessage(context: ThreeCallContext) async -> String

    /// Process gathered search results and decide what action to take
    func processSearchResults(
        context: ThreeCallContext,
        searchResults: [[String: Any]],
        targetGame: String,
        targetSystem: String,
        apiKey: String
    ) async throws -> SearchDecision

    /// Build Call B prompt based on the decision made
    func buildCallBPrompt(decision: SearchDecision, context: ThreeCallContext) -> String
}

/// Represents the decision made after processing search results
enum SearchDecision {
    case launchExact(game: String, command: String, reason: String? = nil)
    case launchAlternative(game: String, command: String, reason: String)
    case gameNotFound(searched: String, suggestions: [String])
    case yoloLaunch(game: String, command: String)
    case needsAISelection(games: [String: String], targetGame: String, userMessage: String)
}

/// Timeout error for search operations
struct SearchTimeoutError: Error {
    let message = "Search timed out"
}

/// Launch Specific Strategy - for direct game requests like "Launch Mario 3"
class LaunchSpecificStrategy: OptimizedSearchStrategy {
    
    func buildSearchTermsPrompt(context: ThreeCallContext) -> String {
        let systemsList = context.availableSystems.joined(separator: ", ")

        // Build context hint from either CLASSIFY pattern or previous search
        var contextHint = ""
        if let actionContext = context.actionContext, !actionContext.isEmpty {
            // CLASSIFY already identified the game (e.g., "Dragon Warrior IV (USA)")
            contextHint = "\n\nCLASSIFY identified: \(actionContext)"
        } else if let prevGame = context.targetGame {
            // Use previous search context as fallback
            if let prevSystem = context.lastSearchSystem {
                contextHint = "\n\nUser was just looking for \(prevGame) on \(prevSystem)"
            } else {
                contextHint = "\n\nUser was just looking for \(prevGame)"
            }
        }

        return """
        Available systems: \(systemsList)\(contextHint)

        User request: "\(context.userMessage)"

        **IMPORTANT: This request came from SPEECH-TO-TEXT, so there may be transcription errors or homophones.**

        **TASK: LAUNCH SPECIFIC - Generate 3 search keyword variations for ROM filename matching**

        **CRITICAL: SINGLE KEYWORDS WORK BEST FOR EXACT MATCHING**
        - ROM searches use literal string matching
        - Single distinctive words find more results: "mario", "zelda", "sonic"
        - Multi-word searches are too narrow and often miss games

        KEYWORD EXTRACTION STRATEGY:
        1. ALWAYS include at least ONE single-word keyword from the game title
        2. Think about how the game title appears in ROM filenames
        3. Consider: single words, abbreviations, MAME names, compound word parts
        4. Account for SPEECH-TO-TEXT ERRORS - include phonetically similar alternatives if unclear
        5. Generate 3 different search approaches (prioritize single words):

        SEARCH TERM TYPES (in priority order):
        1. Single distinctive words: "mario", "zelda", "sonic", "tetris"
        2. Abbreviations: "smw", "sf2", "mk", "mw"
        3. MAME-style: "ddragon", "mk", "sf2ce"
        4. Compound word parts: "mind", "walker", "street", "fighter"
        5. Short multi-word (2-3 words max): "super mario", "street fighter"

        EXAMPLES:
        - "Mario 2" → ["mario", "mario 2", "smb2"]
        - "Mindwalker" → ["mind", "mindwalker", "walker"]
        - "Super Mario World" → ["mario", "super mario", "smw"]
        - "Street Fighter 2" → ["street", "fighter", "sf2"]
        - "Double Dragon" → ["dragon", "double", "ddragon"]
        - "Mortal Kombat" → ["mortal", "kombat", "mk"]

        Return PATTERN C (SEARCH):
        {"searches": ["term1", "term2", "term3"], "target_game": "game title", "system": "SYSTEM or null"}
        """
    }
    
    func buildEnrichedUserMessage(context: ThreeCallContext) async -> String {
        // No additional context needed - buildSearchTermsPrompt already has everything
        return ""
    }
    
    func processSearchResults(
        context: ThreeCallContext,
        searchResults: [[String: Any]],
        targetGame: String,
        targetSystem: String,
        apiKey: String
    ) async throws -> SearchDecision {

        #if DEBUG
        print("🚀 LaunchSpecific: Processing \(searchResults.count) search result sets for '\(targetGame)'")
        #endif
        
        // Flatten all search results into one array
        var allGames: [String: String] = [:] // name -> path
        
        for searchResult in searchResults {
            if let results = searchResult["results"] as? [[String: Any]] {
                for gameResult in results {
                    if let name = gameResult["name"] as? String,
                       let path = gameResult["path"] as? String {
                        allGames[name] = path
                    }
                }
            }
        }

        // Filter out system utility files (mister-boot, etc.)
        let rawGameCount = allGames.count
        allGames = filterSystemUtilityFiles(allGames)
        if rawGameCount > allGames.count {
            #if DEBUG
            print("🚀 LaunchSpecific: Filtered \(rawGameCount - allGames.count) system utility files")
            #endif
        }

        #if DEBUG
        print("🚀 LaunchSpecific: Found \(allGames.count) total games across all searches")
        #endif

        // If no games found, return not found immediately
        if allGames.isEmpty {
            AppLogger.emit(type: .debug, content: "🔧 No games in search results, returning gameNotFound")
            return .gameNotFound(searched: targetGame, suggestions: ["Try re-scanning games in Zaparoo settings", "Check if game exists on MiSTer", "Try different search terms"])
        }
        
        // Delegate to AI for game selection - this follows the ABC pattern
        AppLogger.emit(type: .debug, content: "🔧 Found \(allGames.count) games, delegating to AI for selection")
        return .needsAISelection(games: allGames, targetGame: targetGame, userMessage: context.userMessage)
    }
    
    func buildCallBPrompt(decision: SearchDecision, context: ThreeCallContext) -> String {
        switch decision {
        case .launchExact(let game, _, _):
            // Generate lore-aware response like the original Call B system
            return """
            We launched \(game).
            
            Respond with a short game-specific phrase that shows you know the game.
            
            Examples:
            - Wing Commander 2: "OK Commander Blair!"
            - Donkey Kong Country: "Let's smash barrels!"
            - Street Fighter II: "Time to Choose your fighter!"
            - Mega Man 2: "Lets get Equiped!"
            
            Be enthusiastic but brief. Show that you understand this specific game.
            """
            
        case .gameNotFound(let searched, let suggestions):
            return """
            The user asked you to launch "\(searched)" but you couldn't find it.
            
            Close matches found: \(suggestions.joined(separator: ", "))
            
            Be honest and helpful. Suggest they:
            1. Check the game name spelling
            2. Re-scan their games in Zaparoo settings
            3. Verify the game exists on their MiSTer
            
            User's original request: "\(context.userMessage)"
            
            Keep it brief but helpful - you're Cool Uncle, not a technical manual.
            """
            
        default:
            return "Unexpected decision type for LaunchSpecific strategy"
        }
    }
}

/// Version Switch Strategy - for switching between different versions/platforms of current game
class VersionSwitchStrategy: OptimizedSearchStrategy {

    func buildSearchTermsPrompt(context: ThreeCallContext) -> String {
        let systemsList = context.availableSystems.joined(separator: ", ")
        let currentGame = context.gameContextSnapshot.currentGame ?? "unknown game"
        let currentSystem = context.gameContextSnapshot.currentSystem ?? "unknown system"

        return """
        You are a VERSION SWITCHER. Extract base game name from current game and find variant on different system/region.

        **YOUR TASK: EXTRACT BASE GAME NAME AND DETERMINE TARGET SYSTEM**

        **STEP 1: EXTRACT BASE GAME NAME**
        Remove region/language tags and metadata from current game:
        - "Virtual Bart (USA)" → base: "simpsons" (it's a Simpsons game)
        - "The Simpsons (4 Players World)" → base: "simpsons"
        - "Street Fighter II Turbo (J)" → base: "street fighter"
        - "Final Fantasy VI (USA)" → base: "final fantasy"
        - "Super Mario World [!]" → base: "mario"

        **STEP 2: DETERMINE TARGET SYSTEM**

        **For explicit platform requests:**
        - "NES version" → system: "NES"
        - "arcade version" → system: "Arcade"
        - "SNES version" → system: "SNES"
        - "Genesis version" → system: "Genesis"

        **For language/region requests (SAME system):**
        - "English version" → system: current system (same!)
        - "USA version" → system: current system
        - "Japanese version" → system: current system
        - "PAL version" → system: current system

        **For quality requests (YOUR choice of best system):**
        - "better version" → YOUR CHOICE of best platform
        - "different version" → YOUR CHOICE of interesting alternative

        **For cross-system exploration:**
        - "other versions?" → system: null (search ALL systems)

        **STEP 3: GENERATE 3 DISTINCT SEARCH KEYWORDS**
        Extract 3 DIFFERENT keywords from the base game name:
        1. Primary word from game title
        2. Secondary word or character name
        3. Abbreviated/MAME name if applicable

        **CRITICAL: NO DUPLICATES** - Each search term must be different!

        **EXAMPLES:**

        **Example 1: Cross-Platform Request**
        Current: "Virtual Bart (USA)" on SNES
        User: "Can we play the NES version instead"
        → Base game: "simpsons"
        → Target system: "NES"
        → Searches: ["simpsons", "bart", "simpson"]

        **Example 2: Language Request (Same System)**
        Current: "Street Fighter II (J)" on SNES
        User: "English version please"
        → Base game: "street fighter"
        → Target system: "SNES" (same!)
        → Searches: ["street", "fighter", "sf2"]

        **Example 3: Platform Upgrade**
        Current: "Street Fighter II" on SNES
        User: "arcade version instead"
        → Base game: "street fighter"
        → Target system: "Arcade"
        → Searches: ["street", "fighter", "sf2"]

        **Example 4: Quality Judgment**
        Current: "Mega Man 2" on NES
        User: "better version?"
        → Base game: "mega man"
        → YOUR CHOICE: PSX has Mega Man collections with extras
        → Target system: "PSX"
        → Searches: ["mega", "man", "rockman"]

        Respond in JSON format:
        {
            "searches": ["keyword1", "keyword2", "keyword3"],
            "target_game": "CURRENT_GAME_NAME_WITHOUT_REGION_TAGS",
            "system": "EXACT_SYSTEM_ID" OR null
        }

        **CRITICAL RULES:**
        1. Extract game name from CURRENT game, not from user's request
        2. "target_game" = CURRENT game name with region tags stripped (e.g., "Street Fighter II", "Dr. Mario")
        3. "target_game" should NOT include user's request language (NO "best version of..." or "arcade version of...")
        4. User explicitly names system → HONOR IT (don't second-guess)
        5. User asks for quality → USE YOUR GAMING KNOWLEDGE
        6. ALL 3 SEARCHES MUST BE DIFFERENT - no duplicates!
        7. System must match available systems OR be null

        **EXAMPLES OF CORRECT target_game:**
        - Currently playing: "Street Fighter II Turbo (USA)" → target_game: "Street Fighter II"
        - Currently playing: "Dr. Mario (Japan, USA) (Rev 1)" → target_game: "Dr. Mario"
        - Currently playing: "Super Mario World [!]" → target_game: "Super Mario World"

        Available systems: \(systemsList)

        Currently playing: \(currentGame) on \(currentSystem)
        User request: "\(context.userMessage)"
        """
    }

    func buildEnrichedUserMessage(context: ThreeCallContext) async -> String {
        // Return user message - context is in the prompt
        return context.userMessage
    }

    func processSearchResults(
        context: ThreeCallContext,
        searchResults: [[String: Any]],
        targetGame: String,
        targetSystem: String,
        apiKey: String
    ) async throws -> SearchDecision {

        #if DEBUG
        print("🚀 VersionSwitch: Processing \(searchResults.count) search result sets for '\(targetGame)' on '\(targetSystem)'")
        #endif

        // Flatten all search results into one array
        var allGames: [String: String] = [:] // name -> path

        for searchResult in searchResults {
            if let results = searchResult["results"] as? [[String: Any]] {
                for gameResult in results {
                    if let name = gameResult["name"] as? String,
                       let path = gameResult["path"] as? String {
                        allGames[name] = path
                    }
                }
            }
        }

        // Filter out system utility files (mister-boot, etc.)
        let rawGameCount = allGames.count
        allGames = filterSystemUtilityFiles(allGames)
        if rawGameCount > allGames.count {
            #if DEBUG
            print("🚀 VersionSwitch: Filtered \(rawGameCount - allGames.count) system utility files")
            #endif
        }

        #if DEBUG
        print("🚀 VersionSwitch: Found \(allGames.count) total games across all searches")
        #endif

        // If no games found, explain that version doesn't exist on target system
        if allGames.isEmpty {
            AppLogger.emit(type: .debug, content: "🔧 No games found for version switch on \(targetSystem)")
            return .gameNotFound(
                searched: targetGame,
                suggestions: ["This game may not be available on \(targetSystem)", "Try a different system or version"]
            )
        }

        // Delegate to AI for game selection (picks best ROM quality)
        AppLogger.emit(type: .debug, content: "🔧 Found \(allGames.count) games, delegating to AI for version selection")
        return .needsAISelection(games: allGames, targetGame: targetGame, userMessage: context.userMessage)
    }

    func buildCallBPrompt(decision: SearchDecision, context: ThreeCallContext) -> String {
        let currentGame = context.gameContextSnapshot.currentGame ?? "that game"

        switch decision {
        case .launchExact(let game, _, let selectionReason):
            // Build prompt with AI's selection reasoning if available
            let reasonSection: String
            if let reason = selectionReason {
                reasonSection = """

            **WHY THIS VERSION WAS SELECTED:**
            \(reason)

            Use this reasoning to explain to the user why you picked this version. Make it conversational and enthusiastic!
            """
            } else {
                reasonSection = """

            Respond with enthusiasm about the version switch (2-3 sentences):
            - If they asked for specific platform (NES, arcade, etc) → mention why that platform is cool
            - If they asked for language/region → confirm the switch ("Here's the English version!")
            - If they asked for "better" → briefly explain what makes this version better
            """
            }

            // Enthusiastic response about the version switch
            return """
            You just switched from a different version to: \(game).
            \(reasonSection)

            Examples of enthusiastic responses:
            - "Great choice! The arcade version has smoother gameplay and better graphics!"
            - "Here's the English version so you can follow the story!"
            - "Got it! Here's the NES version for that classic 8-bit experience!"

            Previous game: \(currentGame)
            User requested: "\(context.userMessage)"
            """

        case .gameNotFound(let searched, let suggestions):
            // Extract the helpful AI-generated reason from suggestions array (first element)
            let aiReason = suggestions.first ?? "Could not find the requested version"

            return """
            The user wanted to switch to a different version of the current game, but you couldn't find it.

            The AI provided this reason why the switch failed:
            "\(aiReason)"

            Your task: Convert this technical reason into a natural, conversational response (2-3 sentences max):
            - Be empathetic and helpful
            - Explain why the switch didn't work in plain language
            - If appropriate, suggest they try being more specific or try a different platform

            Examples:
            - AI says "Already playing the best version" → "You're already playing the best version! The arcade version has the best graphics and gameplay."
            - AI says "Game not available on NES" → "Unfortunately, this game was never released on NES. Want to try a different console?"
            - AI says "You're already playing the USA version" → "You're already playing the English USA version!"

            Game they wanted: \(searched)
            User's request: "\(context.userMessage)"
            """

        default:
            return "Unexpected decision type for VersionSwitch strategy"
        }
    }
}

/// Launch Recommended Strategy - for game recommendations like "Recommend me a puzzle game"
class LaunchRecommendedStrategy: OptimizedSearchStrategy {
    
    func buildSearchTermsPrompt(context: ThreeCallContext) -> String {
        let systemsList = context.availableSystems.joined(separator: ", ")

        // Build context hint from either CLASSIFY pattern or previous search
        var contextHint = ""
        if let actionContext = context.actionContext, !actionContext.isEmpty {
            // CLASSIFY already identified context (e.g., game recommendation criteria)
            contextHint = "\n\nCLASSIFY identified: \(actionContext)"
        } else if let prevGame = context.targetGame {
            // Use previous search context as fallback
            if let prevSystem = context.lastSearchSystem {
                contextHint = "\n\nUser was just looking for \(prevGame) on \(prevSystem)"
            } else {
                contextHint = "\n\nUser was just looking for \(prevGame)"
            }
        }

        #if DEBUG
        print("🔧 DEBUG: LaunchRecommendedStrategy.buildSearchTermsPrompt called")
        print("🔧 DEBUG: gamePreferences = '\(context.gamePreferences)'")
        print("🔧 DEBUG: availableSystems = '\(systemsList)'")
        if !contextHint.isEmpty {
            print("🔧 DEBUG: contextHint = '\(contextHint)'")
        }
        #endif

        return """
        Available systems: \(systemsList)\(contextHint)
        """
    }
    
    func buildEnrichedUserMessage(context: ThreeCallContext) async -> String {
        // CACHE OPTIMIZATION: Put stable → dynamic (preferences → avoid list → user request → task)
        var enrichedMessage = ""

        // User preferences (changes slowly - more cacheable)
        if !context.gamePreferences.isEmpty {
            enrichedMessage = context.gamePreferences + "\n\n"
        }

        // Avoid list (changes per session)
        let avoidDays = await MainActor.run {
            let days = UserDefaults.standard.integer(forKey: "avoidGamesDays")
            return days == 0 ? 7 : days
        }
        let recentGames = await MainActor.run {
            UserGameHistoryService.shared.getRecentlyPlayedGames(days: avoidDays)
        }

        if !recentGames.isEmpty {
            enrichedMessage += "**AVOID LIST - RECENTLY PLAYED GAMES:**\n"
            enrichedMessage += recentGames.map { "- \($0)" }.joined(separator: "\n")
            enrichedMessage += "\n\n"
        }

        // User request (changes every time - least cacheable)
        enrichedMessage += "User request: \(context.userMessage)\n\n"

        // Task directive (stable - references system prompt rules)
        enrichedMessage += "**TASK: RECOMMEND - Use PATTERN C: SEARCH TERM GENERATION rules. Return 3 diverse keywords for recommendations.**"

        return enrichedMessage
    }
    
    func processSearchResults(
        context: ThreeCallContext,
        searchResults: [[String: Any]],
        targetGame: String,
        targetSystem: String,
        apiKey: String
    ) async throws -> SearchDecision {

        #if DEBUG
        print("🚀 LaunchRecommended: Processing \(searchResults.count) search result sets for '\(targetGame)'")
        #endif
        
        // Flatten all search results and remove duplicates
        var allGames: [String: String] = [:] // name -> path
        
        for searchResult in searchResults {
            if let results = searchResult["results"] as? [[String: Any]] {
                for gameResult in results {
                    if let name = gameResult["name"] as? String,
                       let path = gameResult["path"] as? String {
                        // Only add if not already present (first occurrence wins)
                        if allGames[name] == nil {
                            allGames[name] = path
                        }
                    }
                }
            }
        }

        // Filter out system utility files (mister-boot, etc.)
        let rawGameCount = allGames.count
        allGames = filterSystemUtilityFiles(allGames)
        if rawGameCount > allGames.count {
            #if DEBUG
            print("🚀 LaunchRecommended: Filtered \(rawGameCount - allGames.count) system utility files")
            #endif
        }

        #if DEBUG
        print("🚀 LaunchRecommended: Found \(allGames.count) unique games across all searches")
        #endif

        // If no games found, execute YOLO search (blank search across all systems)
        if allGames.isEmpty {
            AppLogger.emit(type: .debug, content: "🔧 No games in search results, executing yolo search (blank search across all systems)")
            
            // TODO: Implement actual yolo search execution
            // For now, return gameNotFound - yolo search will be implemented in next step
            return .gameNotFound(searched: targetGame, suggestions: ["Yolo search needs implementation"])
        }
        
        // Use AI to pick the best recommendation from available games
        AppLogger.emit(type: .debug, content: "🔧 Found \(allGames.count) games, delegating to AI for best recommendation selection")
        return .needsAISelection(games: allGames, targetGame: targetGame, userMessage: context.userMessage)
    }
    
    func buildCallBPrompt(decision: SearchDecision, context: ThreeCallContext) -> String {
        switch decision {
        case .launchExact(let game, _, _), .yoloLaunch(let game, _):
            // Generate enthusiastic recommendation response
            return """
            You just recommended and launched "\(game)" for the user.
            
            Provide an enthusiastic 2-3 sentence description of why this is a great choice:
            - What makes this game special or fun
            - Why the user will enjoy it based on their request
            - Show genuine excitement about this recommendation
            
            Examples:
            - "Perfect! Tetris is the ultimate puzzle experience with addictive falling blocks that never get old!"
            - "Excellent choice! Street Fighter II is the king of fighting games with incredible characters and perfect controls!"
            - "Great pick! Super Metroid combines exploration and atmosphere in ways that still amaze players today!"
            
            User's original request: "\(context.userMessage)"
            
            Be Cool Uncle - enthusiastic, knowledgeable, and genuinely excited about this game.
            """
            
        case .gameNotFound(let searched, _):
            // This will trigger yolo search, so provide fallback message
            return """
            The user asked for a recommendation: "\(searched)" but the initial searches didn't find good matches.
            
            You should acknowledge this and indicate you're looking for alternatives:
            "Let me find something great for you from what's available..."
            
            User's original request: "\(context.userMessage)"
            
            Keep it brief and positive - you're about to do a yolo search to find them something.
            """
            
        default:
            return "Unexpected decision type for LaunchRecommended strategy"
        }
    }
}

/// Enhanced OpenAI Service implementing 3-call architecture with shared context
/// 
/// **Architecture**: Separates concerns across 3 specialized API calls with context sharing:
/// - CALL A: JSON command generation with game history + last 15 messages (T=0.2)
/// - CALL B: Cool Uncle speech knowing the action taken + last 25 messages (T=0.8) 
/// - CALL C: Sentiment analysis with full context for preference learning (T=0.3)
///
/// **Benefits**:
/// - 99% JSON reliability with response_format enforcement
/// - Smart context sharing between calls for coherent responses
/// - Specialized prompts optimized for each call's purpose
/// - Cool Uncle can reference actions taken and user preferences
/// - Better cost control with targeted, context-aware prompts

// MARK: - Utility Functions

/// Filter out system utility files that should never be selected as games
/// - Parameter games: Dictionary of game names to paths
/// - Returns: Filtered dictionary with system utility files removed
func filterSystemUtilityFiles(_ games: [String: String]) -> [String: String] {
    let systemUtilityPatterns = [
        "mister-boot",
        "system-boot",
        "bios",
        "firmware"
    ]

    return games.filter { (gameName, _) in
        let normalized = gameName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if this is a system utility file
        for pattern in systemUtilityPatterns {
            if normalized.hasPrefix(pattern) || normalized == pattern {
                AppLogger.verbose("🚫 Filtered system utility: \(gameName)")
                return false // Exclude this file
            }
        }
        return true // Keep this file
    }
}

@MainActor
class EnhancedOpenAIService: ObservableObject {
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var showAPIKeyError = false  // Triggered on 401/authentication errors

    // Results from the 3-call flow
    @Published var generatedCommand: String?
    @Published var commandExecutionResult: String?
    @Published var coolUncleResponse: String = ""
    @Published var threeCallContext: ThreeCallContext?
    
    // Pending response tracking for deferred Call B
    private var pendingContext: ThreeCallContext?
    private var pendingExecutionResult: String?
    private var pendingApiKey: String?
    private var pendingSelectionReason: String? // AI's reasoning for game selection (version_switch)
    private var pendingStrategy: OptimizedSearchStrategy? // Strategy for building Call B prompt
    private var pendingDecision: SearchDecision? // Decision made during search (for strategy Call B prompt)
    
    // Cancellation state management (minimal two-chokepoint system)
    private var _isCancellationRequested = false
    var isCancellationRequested: Bool {
        get { _isCancellationRequested || Task.isCancelled }
    }

    // Cloudflare proxy configuration
    // BYOK (Bring Your Own Key) mode: Set to false for direct OpenAI API calls
    // Set to true only if you're running your own Cloudflare Worker proxy
    private let useCloudflareProxy = false
    private let cloudflareProxyURL = "https://cooluncle-backend.cooluncle.workers.dev/chat"
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private var currentTask: Task<Void, Never>?

    // Network configuration
    private let requestTimeoutSeconds: TimeInterval = 8.0  // Timeout per attempt
    private let maxRetries: Int = 1  // Retry once on timeout (2 total attempts)

    // Debug flag for testing network timeout handling (controlled via launch argument)
    #if DEBUG
    private var simulateNetworkTimeout: Bool {
        return CommandLine.arguments.contains("-SimulateNetworkTimeout")
    }
    #endif
    
    // Service-level backup storage for yolo search - independent of context lifecycle
    
    // Service-level storage for pending recommendation confirmation
    private var pendingRecommendationCommand: String?
    private var pendingRecommendationGameName: String?
    private var pendingRecommendationTimestamp: Date?
    private let CACHE_EXPIRATION_SECONDS: TimeInterval = 90 // 1.5 minutes

    // Snapshot preservation for stopped game context
    private var lastStopGameSnapshot: GameContextSnapshot?
    private var lastStopGameTimestamp: Date?
    private let STOP_GAME_CONTEXT_EXPIRATION_SECONDS: TimeInterval = 600 // 10 minutes

    // MARK: - Consumer UI Integration

    /// UI state service for transient status updates
    private var uiStateService: UIStateService?

    /// Chat bubble service for persistent message history
    private var chatBubbleService: ChatBubbleService?

    /// Inject UI state service (called by ConsumerView on appear)
    func setUIStateService(_ service: UIStateService) {
        self.uiStateService = service
    }

    /// Inject chat bubble service (called by ConsumerView on appear)
    func setChatBubbleService(_ service: ChatBubbleService) {
        self.chatBubbleService = service
    }

    // MARK: - Stop Game Context Management

    /// Get the preserved stop game snapshot if available and valid
    func getLastStopGameSnapshot() -> GameContextSnapshot? {
        guard isStopGameContextValid() else {
            // Clear expired context
            clearStopGameContext()
            return nil
        }
        return lastStopGameSnapshot
    }

    /// Check if stop game context is still valid (not expired)
    func isStopGameContextValid() -> Bool {
        guard let timestamp = lastStopGameTimestamp,
              lastStopGameSnapshot != nil else {
            return false
        }

        return Date().timeIntervalSince(timestamp) < STOP_GAME_CONTEXT_EXPIRATION_SECONDS
    }

    /// Clear stop game context (called on new game launches or timeout)
    private func clearStopGameContext() {
        if lastStopGameSnapshot != nil {
            AppLogger.gameHistory("🧹 Clearing stopped game context")
        }
        lastStopGameSnapshot = nil
        lastStopGameTimestamp = nil
    }
    
    // MARK: - Optimized Search Properties
    
    /// Storage for search results during optimized search execution
    private var optimizedSearchResults: [[String: Any]] = []
    
    /// Actor-based management for per-search continuations and buffered results
    private actor SearchResultManager {
        struct PendingSearch {
            var continuation: CheckedContinuation<[String: Any], Error>?
            var bufferedResult: [String: Any]?
            var hasTimedOut: Bool
        }
        
        enum RegistrationOutcome {
            case awaitingResult
            case fulfilledFromBuffer
        }
        
        enum ResultOutcome {
            case resumedActiveContinuation
            case bufferedAfterTimeout
            case bufferedAwaitingContinuation
        }
        
        enum TimeoutOutcome {
            case resumedWithTimeout
            case alreadyResolved
        }
        
        private var pendingSearches: [String: PendingSearch] = [:]
        
        func registerContinuation(
            _ continuation: CheckedContinuation<[String: Any], Error>,
            for searchID: String
        ) -> RegistrationOutcome {
            var entry = pendingSearches[searchID] ?? PendingSearch(continuation: nil, bufferedResult: nil, hasTimedOut: false)
            
            if let buffered = entry.bufferedResult {
                // Result already arrived before registration - resume immediately
                entry.continuation = nil
                entry.hasTimedOut = false
                pendingSearches[searchID] = entry
                continuation.resume(returning: buffered)
                return .fulfilledFromBuffer
            } else {
                entry.continuation = continuation
                pendingSearches[searchID] = entry
                return .awaitingResult
            }
        }
        
        func handleResult(_ result: [String: Any], for searchID: String) -> ResultOutcome {
            var entry = pendingSearches[searchID] ?? PendingSearch(continuation: nil, bufferedResult: nil, hasTimedOut: false)
            entry.bufferedResult = result
            
            if let continuation = entry.continuation {
                entry.continuation = nil
                entry.hasTimedOut = false
                pendingSearches[searchID] = entry
                continuation.resume(returning: result)
                return .resumedActiveContinuation
            } else {
                pendingSearches[searchID] = entry
                return entry.hasTimedOut ? .bufferedAfterTimeout : .bufferedAwaitingContinuation
            }
        }
        
        func handleTimeout(for searchID: String) -> TimeoutOutcome {
            guard var entry = pendingSearches[searchID] else {
                // Track timeout state so late arrivals are marked correctly
                pendingSearches[searchID] = PendingSearch(continuation: nil, bufferedResult: nil, hasTimedOut: true)
                return .alreadyResolved
            }
            
            if let continuation = entry.continuation {
                entry.continuation = nil
                entry.hasTimedOut = true
                pendingSearches[searchID] = entry
                continuation.resume(throwing: SearchTimeoutError())
                return .resumedWithTimeout
            } else {
                entry.hasTimedOut = true
                pendingSearches[searchID] = entry
                return .alreadyResolved
            }
        }
        
        func results(inOrder searchIDs: [String]) -> [[String: Any]] {
            searchIDs.compactMap { pendingSearches[$0]?.bufferedResult }
        }
        
        func clear(searchIDs: [String]) {
            for id in searchIDs {
                pendingSearches.removeValue(forKey: id)
            }
        }
    }
    
    /// Async-safe search result manager
    private let searchResultManager = SearchResultManager()

    // MARK: - Search Batch Tracking

    /// Tracks active search batch to ignore late results
    private struct SearchBatch {
        let batchID: UUID                 // Unique ID for this batch of searches
        let searchIDs: Set<String>        // Individual search IDs in this batch
        let actionType: String            // "recommend", "launch_specific", etc.
        let createdAt: Date               // When batch was created
        var isCompleted: Bool = false     // Marked true when executeSearchesSequentially() finishes

        func isExpired(timeout: TimeInterval = 5.0) -> Bool {
            Date().timeIntervalSince(createdAt) > timeout
        }
    }

    /// Active search batch (nil = no active searches)
    private var activeSearchBatch: SearchBatch? = nil

    /// Check if a search ID belongs to the currently active batch
    func isSearchInActiveBatch(_ searchID: String) -> Bool {
        guard let batch = activeSearchBatch else {
            return false // No active batch
        }

        // Check if batch is completed (searches finished, either all completed or guard timer expired)
        if batch.isCompleted {
            #if DEBUG
            print("⏰ Active batch completed, considering search \(searchID) as invalid")
            #endif
            activeSearchBatch = nil
            return false
        }

        return batch.searchIDs.contains(searchID.lowercased())
    }

    /// Get current batch info for debugging
    func getActiveBatchInfo() -> String? {
        guard let batch = activeSearchBatch else {
            return nil
        }
        return "Batch \(batch.batchID): \(batch.searchIDs.count) searches, age: \(Date().timeIntervalSince(batch.createdAt))s"
    }

    /// Track current search strategy being used
    private var currentSearchStrategy: OptimizedSearchStrategy?
    
    /// Flag to indicate if we're currently using optimized search (prevents old retry logic)
    var isUsingOptimizedSearch: Bool = false
    
    // MARK: - Feature Flags
    
    /// Enable optimized search for launch_specific (GENERATE pattern)
    private let useOptimizedLaunchSpecific: Bool = true // Set to false to disable
    
    /// Enable optimized search for recommend workflows (Phase 3)
    private let useOptimizedRecommend: Bool = true // Set to false to disable
    
    // Public method to set pending recommendation
    func setPendingRecommendation(command: String, gameName: String) {
        pendingRecommendationCommand = command
        pendingRecommendationGameName = gameName
        pendingRecommendationTimestamp = Date()
        AppLogger.openAI("📌 Cached recommendation: \(gameName)")
    }
    
    // Clear pending recommendation
    func clearPendingRecommendation() {
        pendingRecommendationCommand = nil
        pendingRecommendationGameName = nil
        pendingRecommendationTimestamp = nil
    }
    
    // Validate pending recommendation (not expired)
    func isPendingRecommendationValid() -> Bool {
        guard let timestamp = pendingRecommendationTimestamp else { return false }
        if Date().timeIntervalSince(timestamp) > CACHE_EXPIRATION_SECONDS {
            #if DEBUG
            print("⏰ Cache expired after \(Int(CACHE_EXPIRATION_SECONDS))s idle")
            #endif
            AppLogger.aiResponse("⏰ Recommendation cache expired after \(CACHE_EXPIRATION_SECONDS)s - clearing cached command")
            clearPendingRecommendation()
            return false
        }
        return pendingRecommendationCommand != nil
    }
    
    // MARK: - Main 3-Call Flow
    
    /// Execute the complete 3-call flow with context sharing: Command → Speech → Sentiment
    func processUserMessage(
        userMessage: String,
        conversationHistory: [ChatMessage],
        availableSystems: [String],
        gameContextSnapshot: GameContextSnapshot,
        preservedActionType: String? = nil,
        apiKey: String,
        onCommandGenerated: @escaping (String) -> Void,
        onCommandExecuted: @escaping (String) -> Void
    ) async {
        // DEBUG: Track search result processing
        if userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") {
            AppLogger.emit(type: .debug, content: "processUserMessage called with SEARCH RESULTS")
            AppLogger.emit(type: .debug, content: "Call stack trace - search results processing")
            AppLogger.emit(type: .debug, content: "Preserved action type: \(preservedActionType ?? "nil")")
            AppLogger.emit(type: .debug, content: "Current context exists: \(threeCallContext != nil)")
            if let context = threeCallContext {
                AppLogger.emit(type: .debug, content: "Current context actionType: \(context.actionType ?? "nil")")
                AppLogger.emit(type: .debug, content: "Current context available")
            }
        }
        
        isLoading = true
        lastError = nil

        // Show initial status
        Task { @MainActor in
            uiStateService?.showStatus("Asking the AI...")
        }

        // Build initial context with game history and preferences
        let gameHistory = UserGameHistoryService.shared.getGameContextSummary()
        let gamePreferences = GamePreferenceService.shared.getPreferenceContextForAI()
        
        // CRITICAL: Use existing context if available (preserves state)
        var context: ThreeCallContext
        if let existingContext = self.threeCallContext,
           userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") {
            // This is search result processing - preserve existing context state
            context = existingContext
            context.userMessage = userMessage // Update with new message
            context.conversationHistory = conversationHistory // Update conversation
            context.gameContextSnapshot = gameContextSnapshot // Update snapshot

            // STDIO logging for immediate Xcode visibility
            #if DEBUG
            print("✅ CONTEXT PRESERVED: actionType=\(context.actionType ?? "nil")")
            #endif
            
            AppLogger.emit(type: .debug, content: "PRESERVING existing context:")
            AppLogger.emit(type: .debug, content: "   context preserved")
            AppLogger.emit(type: .debug, content: "   originalSearchQuery: \(context.originalSearchQuery ?? "nil")")
            AppLogger.emit(type: .debug, content: "   actionType: \(context.actionType ?? "nil")")
            AppLogger.emit(type: .debug, content: "   previousFailureReason: \(context.previousFailureReason ?? "nil")")
        } else {
            // This is a new user request - create fresh context

            // Invalidate any active search batch
            if let batch = activeSearchBatch {
                #if DEBUG
                print("🗑️ Invalidating previous search batch: \(batch.batchID)")
                print("   Reason: New user request received")
                print("   Previous batch had \(batch.searchIDs.count) searches")
                #endif
                activeSearchBatch = nil
            }

            let hasExistingContext = self.threeCallContext != nil
            let isSearchResults = userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]")

            // Preserve previous search context for follow-up requests
            let previousTargetGame = hasExistingContext ? self.threeCallContext?.targetGame : nil
            let previousSearchSystem = hasExistingContext ? self.threeCallContext?.lastSearchSystem : nil

            #if DEBUG
            if hasExistingContext && (previousTargetGame != nil || previousSearchSystem != nil) {
                print("✅ PRESERVING SEARCH CONTEXT: game=\(previousTargetGame ?? "nil"), system=\(previousSearchSystem ?? "nil")")
            } else {
                print("🆕 CREATING FRESH CONTEXT: No previous search context to preserve")
            }
            #endif

            context = ThreeCallContext(
                userMessage: userMessage,
                conversationHistory: conversationHistory,
                gameHistory: gameHistory,
                gamePreferences: gamePreferences,
                availableSystems: availableSystems,
                gameContextSnapshot: gameContextSnapshot
            )

            // Carry forward previous search context (unless this is a search results processing message)
            if hasExistingContext && !isSearchResults {
                context.targetGame = previousTargetGame
                context.lastSearchSystem = previousSearchSystem
                AppLogger.emit(type: .debug, content: "CARRIED FORWARD previous search context: game=\(previousTargetGame ?? "nil"), system=\(previousSearchSystem ?? "nil")")
            } else {
                AppLogger.emit(type: .debug, content: "CREATED fresh context for new user request")
            }
        }
        
        // If we have a preserved action type (from search result processing), use it
        if let preservedActionType = preservedActionType {
            context.actionType = preservedActionType
            AppLogger.emit(type: .debug, content: "Using preserved actionType: \(preservedActionType)")
            // CRITICAL: Don't overwrite originalSearchQuery during search result processing
            // It should already be set from the original user request
            if context.originalSearchQuery == nil {
                AppLogger.emit(type: .debug, content: "originalSearchQuery was nil during search processing - this shouldn't happen")
            } else {
                AppLogger.emit(type: .debug, content: "Preserving originalSearchQuery: \(context.originalSearchQuery!)")
            }
        } else {
            // This is a new user message - preserve the original search query for retries
            context.originalSearchQuery = userMessage
            AppLogger.emit(type: .debug, content: "Set original search query: \(userMessage)")
        }
        
        do {
            // Update status for Call A
            Task { @MainActor in
                uiStateService?.showStatus("Classifying request...")
            }

            // CALL A: Generate JSON command with game history + last 15 messages
            AppLogger.emit(type: .debug, content: "CALL A: Generating JSON command with context")
            context = try await executeCallA_JSONGeneration(context: context, apiKey: apiKey)

            // CRITICAL CHECKPOINT: Check cancellation AFTER Call A completes
            // Call A is an async network request that can't be stopped mid-flight,
            // but we can prevent continuing the pipeline after it returns
            guard !isCancellationRequested else {
                AppLogger.standard("🛑 Cancellation detected after Call A - stopping pipeline")
                isLoading = false
                return
            }

            // CRITICAL: Set threeCallContext immediately after Call A so it's available for zero results handling
            self.threeCallContext = context
            AppLogger.emit(type: .debug, content: "Set threeCallContext for potential zero results handling")

            AppLogger.emit(type: .debug, content: "   Action Type: \(context.actionType ?? "unknown")")
            AppLogger.emit(type: .debug, content: "   Action Context: \(context.actionContext ?? "none")")
            
            // 🚀 NEW OPTIMIZED PATH: Check for launch_specific and route to fast path
            if context.actionType == "launch_specific" && !userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") && useOptimizedLaunchSpecific {
                #if DEBUG
                print("🚀 DETECTED launch_specific - routing to optimized path (feature flag: \(useOptimizedLaunchSpecific))")
                #endif
                
                do {
                    // Execute the optimized launch_specific search using strategy pattern
                    let strategy = LaunchSpecificStrategy()
                    context = try await executeOptimizedSearch(
                        strategy: strategy,
                        context: context,
                        apiKey: apiKey,
                        onCommandGenerated: onCommandGenerated,
                        onCommandExecuted: onCommandExecuted
                    )
                } catch is CancellationError {
                    // User cancelled - exit silently without any error message
                    AppLogger.standard("✅ Launch specific search cancelled by user")
                    isUsingOptimizedSearch = false
                    currentSearchStrategy = nil
                    isLoading = false
                    return  // Exit early - "Request stopped" bubble already shown

                } catch {
                    #if DEBUG
                    print("❌ OPTIMIZED SEARCH: Failed with error: \(error)")
                    #endif

                    // Provide humorous fallback message
                    let fallbackMessages = [
                        "The Nintendo ninjas have locked down that system... Or you don't have games for that system or forgot to re-scan your games on zaparoo.",
                        "Corporate won't let me access that system right now... Or you don't have games for that system or forgot to re-scan your games on zaparoo.",
                        "The system overlords are blocking me... Or you don't have games for that system or forgot to re-scan your games on zaparoo."
                    ]

                    let randomMessage = fallbackMessages.randomElement() ?? fallbackMessages[0]
                    context.coolUncleResponse = randomMessage

                    // Set the published response property
                    AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(randomMessage)' via EnhancedOpenAIService:660 OPTIMIZED_SEARCH_FALLBACK")
                    self.coolUncleResponse = randomMessage

                    // Clear optimized search flags on error
                    isUsingOptimizedSearch = false
                    currentSearchStrategy = nil

                    onCommandExecuted("Game search failed")
                }
                
                // Update the service context and published response
                self.threeCallContext = context
                let newResponse = context.coolUncleResponse ?? ""
                AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(newResponse)' via EnhancedOpenAIService:671 OPTIMIZED_SEARCH_SUCCESS")
                self.coolUncleResponse = newResponse
                isLoading = false
                return
            }
            
            // Debug logging for yolo search routing
            if (context.actionType == "recommend" || context.actionType == "recommend_alternative") &&
               context.recommendationSource == "yolo" {
                AppLogger.emit(type: .launchRouting, content: "YOLO SEARCH ROUTING: Forcing legacy pathway for yolo results (actionType: \(context.actionType ?? "nil"), source: \(context.recommendationSource ?? "nil"))")
            }

            // 🚀 NEW OPTIMIZED PATH: Check for recommend (including recommend_confirm) and route to optimized fast path
            if (context.actionType == "recommend" || context.actionType == "recommend_alternative" || context.actionType == "recommend_confirm") &&
               !userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") &&
               context.recommendationSource != "yolo" && useOptimizedRecommend {
                AppLogger.emit(type: .launchRouting, content: "DETECTED recommend - routing to optimized path (feature flag: \(useOptimizedRecommend))")

                do {
                    // Execute the optimized recommend search using strategy pattern
                    let strategy = LaunchRecommendedStrategy()
                    context = try await executeOptimizedSearch(
                        strategy: strategy,
                        context: context,
                        apiKey: apiKey,
                        onCommandGenerated: onCommandGenerated,
                        onCommandExecuted: onCommandExecuted
                    )
                } catch is CancellationError {
                    // User cancelled - exit silently without any error message
                    AppLogger.standard("✅ Recommend search cancelled by user")
                    isUsingOptimizedSearch = false
                    currentSearchStrategy = nil
                    isLoading = false
                    return  // Exit early - "Request stopped" bubble already shown

                } catch {
                    #if DEBUG
                    print("❌ OPTIMIZED RECOMMEND: Failed with error: \(error)")
                    #endif

                    // Provide humorous fallback message
                    let fallbackMessages = [
                        "My recommendation engine needs a coffee break... Let me try the old-fashioned way!",
                        "The game recommendation council is in session... Please hold while I consult them!",
                        "My crystal ball is cloudy today... Let me shake it and try again!"
                    ]

                    let randomMessage = fallbackMessages.randomElement() ?? fallbackMessages[0]
                    context.coolUncleResponse = randomMessage

                    // Set the published response property
                    self.coolUncleResponse = randomMessage

                    // Clear optimized search flags on error
                    isUsingOptimizedSearch = false
                    currentSearchStrategy = nil

                    onCommandExecuted("Recommendation search failed")
                }
                
                // Update the service context and published response
                self.threeCallContext = context
                self.coolUncleResponse = context.coolUncleResponse ?? ""
                isLoading = false
                return
            }

            // 🚀 NEW OPTIMIZED PATH: Check for version_switch and route to optimized fast path
            if context.actionType == "version_switch" {
                AppLogger.emit(type: .launchRouting, content: "DETECTED version_switch - routing to optimized path")

                do {
                    // Execute the optimized version_switch search using strategy pattern
                    let strategy = VersionSwitchStrategy()
                    context = try await executeOptimizedSearch(
                        strategy: strategy,
                        context: context,
                        apiKey: apiKey,
                        onCommandGenerated: onCommandGenerated,
                        onCommandExecuted: onCommandExecuted
                    )
                } catch is CancellationError {
                    // User cancelled - exit silently without any error message
                    AppLogger.standard("✅ Version switch cancelled by user")
                    isUsingOptimizedSearch = false
                    currentSearchStrategy = nil
                    isLoading = false
                    return  // Exit early - "Request stopped" bubble already shown

                } catch {
                    #if DEBUG
                    print("❌ OPTIMIZED VERSION SWITCH: Failed with error: \(error)")
                    #endif

                    // Provide helpful fallback message
                    let fallbackMessage = "Hmm, I couldn't find that version of the game. It might not be available on that system, or you might need to re-scan your games in Zaparoo settings."

                    context.coolUncleResponse = fallbackMessage

                    // Set the published response property
                    AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(fallbackMessage)' via EnhancedOpenAIService VERSION_SWITCH_FALLBACK")
                    self.coolUncleResponse = fallbackMessage

                    // Clear optimized search flags on error
                    isUsingOptimizedSearch = false
                    currentSearchStrategy = nil

                    onCommandExecuted("Version switch failed")
                }

                // Update the service context and published response
                self.threeCallContext = context
                self.coolUncleResponse = context.coolUncleResponse ?? ""
                isLoading = false
                return
            }

            // Clear cached recommendation for new game-related actions
            if let actionType = context.actionType {
                let cacheClearingActions = ["launch_specific", "random", "recommend", 
                                            "recommend_alternative", "recommend_confirm",
                                            "search", "stop_game", "alternative"]
                
                if cacheClearingActions.contains(actionType) && 
                   actionType != "confirm_yes" && actionType != "confirm_no" && actionType != "confirm_info" {
                    
                    // Special case: recommend_confirm might be for a new game while one is cached
                    if actionType == "recommend_confirm" && isPendingRecommendationValid() {
                        #if DEBUG
                        print("🔄 Cache cleared: new recommendation requested")
                        #endif
                        AppLogger.session("🔄 New recommendation requested - clearing old cached recommendation")
                        clearPendingRecommendation()
                    } else if actionType != "recommend_confirm" {
                        // Clear cache for any other game-related action
                        if pendingRecommendationCommand != nil {
                            #if DEBUG
                            print("🔄 Cache cleared: new action '\(actionType)'")
                            #endif
                            AppLogger.session("🔄 Action '\(actionType)' detected - clearing recommendation cache")
                            clearPendingRecommendation()
                        }
                    }
                }
            }
            
            var executionResult = "No command executed - informational question"
            var isRandomLaunch = false


            // Check if we have a command to execute
            if let jsonCommand = context.jsonCommand {
                // CHOKEPOINT 1: Block command if user pressed STOP
                // This prevents game launches, save/load states, and ALL MiSTer commands
                guard !isCancellationRequested else {
                    AppLogger.standard("🛑 CHOKEPOINT 1: Command generation cancelled - not sending to MiSTer")
                    isLoading = false
                    return
                }

                generatedCommand = jsonCommand
                AppLogger.emit(type: .debug, content: "CALL A: Generated command: \(jsonCommand)")
                
                // DEBUG: Track command generation details
                if jsonCommand.contains("\"method\":\"launch\"") {
                    AppLogger.emit(type: .debug, content: "LAUNCH command generated from AI!")
                    if jsonCommand.contains("\"text\"") {
                        AppLogger.emit(type: .debug, content: "Launch uses 'text' parameter (correct)")
                    }
                    if jsonCommand.contains("\"path\"") {
                        AppLogger.emit(type: .debug, content: "Launch uses 'path' parameter (INCORRECT!)")
                    }
                }
                
                // Legacy search command storage removed - optimized search handles retries internally

                // Execute command and get result summary
                generatedCommand = jsonCommand  // Set for UI display
                onCommandGenerated(jsonCommand)
                
                // For random launches, don't wait - let media.started notification trigger the response
                isRandomLaunch = context.actionType == "random"
                
                if !isRandomLaunch {
                    // For non-random launches, configurable wait for command execution
                    if TimingConfig.commandExecutionDelay > 0 {
                        AppLogger.openAI("⏳ Waiting \(TimingConfig.delayInMs(TimingConfig.commandExecutionDelay))ms for command execution (action_type: \(context.actionType ?? "unknown"))")
                        try await Task.sleep(nanoseconds: TimingConfig.commandExecutionDelay)
                    }
                    executionResult = commandExecutionResult ?? "Command executed successfully"
                    onCommandExecuted(executionResult)
                } else {
                    // For random launches, execute immediately - response will be generated when actual game arrives
                    AppLogger.openAI("🎲 Random launch detected - executing immediately, response will be generated when game arrives")
                    executionResult = "Random command sent - waiting for actual game"
                    onCommandExecuted(executionResult)
                    AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: onCommandExecuted callback completed, continuing to UNIVERSAL LAUNCH ESCAPE HATCH")
                }
                
                // ✅ UNIVERSAL LAUNCH COMMAND ESCAPE HATCH
                // After successful command execution, proceed directly to Call B - don't fall through to retry logic
                AppLogger.openAI("✅ Command executed successfully - proceeding to Call B")
                AppLogger.openAI("🚫 LAUNCH ESCAPE HATCH: Skipping all search retry logic")
                
                // Preserve action context for Call B
                context.actionContext = buildActionContextForCallB(
                    originalAction: context.actionType,
                    userMessage: context.originalSearchQuery ?? context.userMessage,
                    launchCommand: jsonCommand
                )
            } else {
                // Legacy retry logic removed - optimized search handles all retry scenarios
                AppLogger.standard("💬 CALL A: No launch command generated")
                
                // For search results that don't generate launch commands, let optimized search handle it
                if context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") {
                    AppLogger.standard("🔄 Search results processed - optimized search will handle retry if needed")
                    executionResult = "Search completed but no suitable games found"
                    
                    // Generate appropriate user response
                    if context.actionType == "recommend" || 
                       context.actionType == "recommend_alternative" || 
                       context.actionType == "recommend_confirm" {
                        // Generate Cool Uncle's humorous response
                        let humorResponse = generateCoolUncleResponseYoloSearchFailed(context.originalSearchQuery ?? context.userMessage)
                        AppLogger.standard("😄 COOL UNCLE RESPONSE: \(humorResponse)")
                        executionResult = humorResponse
                        coolUncleResponse = humorResponse
                        context.coolUncleHumorSet = true
                    } else {
                        // Simple response for direct searches
                        executionResult = "No suitable games found"
                    }
                } else {
                    AppLogger.openAI("💬 CALL A: No command generated - informational question detected")
                    // Skip command execution for informational questions
                }
            }
            
            AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: Reached end of command execution if-else block, about to start CALL B section")

            // Update status for Call B
            Task { @MainActor in
                uiStateService?.showStatus("Generating response...")
            }

            // CALL B: Generate Cool Uncle response knowing what action was taken
            // DEBUG: Track actionType at start of Call B routing
            AppLogger.emit(type: .standard, content: "🐛 CALL B ROUTING DEBUG: actionType='\(context.actionType ?? "nil")' jsonCommand='\(context.jsonCommand ?? "nil")' userMessage starts with SEARCH_RESULTS: \(context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]"))")
            
            // Skip Cool Uncle response for input commands (utility commands should execute silently)
            if isInputCommand(context.jsonCommand) {
                AppLogger.openAI("⏭️ CALL B: Skipping response for input command - utility commands execute silently")
                coolUncleResponse = ""
            // Skip Cool Uncle response for search commands (media.search) but not launch commands
            } else if isSearchCommand(context.jsonCommand) {
                AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: Hit isSearchCommand branch - NOT random launch")
                AppLogger.openAI("⏭️ CALL B: Skipping response for search command - waiting for results")
                coolUncleResponse = "" // Empty response for search commands
            } else if context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") && !isLaunchCommand(context.jsonCommand) {
                AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: Hit SEARCH_RESULTS branch - NOT random launch")
                if context.coolUncleHumorSet {
                    AppLogger.openAI("🎭 CALL B: Preserving Cool Uncle humor - not clearing response")
                    // Don't clear coolUncleResponse, humor stays intact for text-to-speech
                } else {
                    AppLogger.openAI("⏭️ CALL B: Skipping Cool Uncle response for search result processing (not launch)")
                    coolUncleResponse = "" // Empty response during search result processing - final response will be generated after launch
                }
            } else if context.coolUncleHumorSet && !coolUncleResponse.isEmpty {
                // CRITICAL FIX: If Cool Uncle humor is set, always preserve it regardless of other conditions
                AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: Hit coolUncleHumorSet branch - NOT random launch")
                AppLogger.openAI("🎭 CALL B: Cool Uncle humor is set and response exists - preserving for text-to-speech")
                // Keep coolUncleResponse intact for text-to-speech
            } else if (context.actionType == "confirm_yes" || 
                      context.actionType == "confirm_no" || 
                      context.actionType == "confirm_info") && 
                     !isPendingRecommendationValid() {
                // Handle confirm actions with no cache - do nothing
                #if DEBUG
                print("⚠️ No cache, no B call: \(context.actionType ?? "unknown") ignored")
                #endif
                AppLogger.aiResponse("⚠️ CALL B: \(context.actionType ?? "unknown") detected but no cached recommendation - command ignored, no response generated")
                coolUncleResponse = "" // Do nothing - no response
            } else if context.actionType == "recommend_confirm" && 
                      commandExecutionResult?.contains("Recommendation cached") == true &&
                      isPendingRecommendationValid() {
                // ONLY for recommend_confirm with freshly cached command (not expired)
                // Generate confirmation prompt immediately
                AppLogger.openAI("🎯 CALL B: Generating confirmation prompt for cached recommendation")
                context = try await executeCallB_SpeechGeneration(
                    context: context, 
                    executionResult: "Ready to launch \(pendingRecommendationGameName ?? "the game")",
                    apiKey: apiKey
                )
                
                guard let speech = context.coolUncleResponse else {
                    throw OpenAIServiceError.emptyResponse
                }
                
                coolUncleResponse = speech
                AppLogger.openAI("✅ CALL B: Generated confirmation prompt: \(speech)")
            } else if context.actionType == "recommend_confirm" &&
                      isLaunchCommand(context.jsonCommand) {
                // Intercept recommend_confirm launch immediately to avoid race with UI layer caching
                // Ensure the pending recommendation cache is set, then generate confirmation prompt
                if !isPendingRecommendationValid(), let cmd = context.jsonCommand,
                   let data = cmd.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let params = json["params"] as? [String: Any],
                   let text = params["text"] as? String {
                    // Derive a human-readable game name from the path
                    let lastComponent = (text as NSString).lastPathComponent
                    let gameName = lastComponent.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
                    setPendingRecommendation(command: cmd, gameName: gameName)
                    // Provide a deterministic execution result for routing (no sleeps/races)
                    commandExecutionResult = "Recommendation cached - awaiting confirmation"
                }
                
                // Generate confirmation prompt now that cache is present
                AppLogger.openAI("🎯 CALL B: Generating confirmation prompt for cached recommendation (service-side)")
                context = try await executeCallB_SpeechGeneration(
                    context: context,
                    executionResult: "Ready to launch \(pendingRecommendationGameName ?? "the game")",
                    apiKey: apiKey
                )
                
                guard let speech = context.coolUncleResponse else {
                    throw OpenAIServiceError.emptyResponse
                }
                coolUncleResponse = speech
                AppLogger.openAI("✅ CALL B: Generated confirmation prompt: \(speech)")
            } else if context.actionType == "random" {
                // For ALL random commands, skip Call B here since handleRandomGameLaunch() will generate the response
                AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: actionType='\(context.actionType ?? "nil")' - MATCHED condition, skipping Call B")
                AppLogger.openAI("⏭️ CALL B: Skipping response for random launch - handleRandomGameLaunch() will generate response")
                coolUncleResponse = "" // Empty response - handleRandomGameLaunch() will provide proper response
            } else if context.actionType == "game_not_found" {
                // 🚀 NEW: Handle game_not_found action type
                #if DEBUG
                print("🚀 CALL B: Generating game_not_found response")
                #endif

                let targetGame = context.targetGame ?? "that game"
                let speech = """
                Sorry, I couldn't find \(targetGame) in your collection. If you recently added it, I can refresh the Zaparoo database to pick up new games. Would you like me to do that?
                """

                AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(speech)' via EnhancedOpenAIService:901 GAME_NOT_FOUND_CALL_B")
                #if DEBUG
                print("🚀 CALL B: Generated game_not_found response: \(speech)")
                #endif

                // Use centralized canned response helper (handles UI clearing)
                setCannedResponse(speech)
            } else if context.actionType == "system_not_available" {
                // Handle system_not_available with canned response (no expensive Call B needed)
                AppLogger.openAI("🚫 CALL B: System not available - using canned response (no AI call)")

                // Get system name directly from action_context (Call A returns just the system name)
                let systemName = context.actionContext ?? "that system"

                let speech = """
                Sorry, but \(systemName) isn't available on your MiSTer yet. You'll need to copy over some games for that system, then re-scan your Zaparoo list to make them available for me.
                """

                AppLogger.openAI("✅ CALL B: Generated system_not_available canned response: \(speech)")

                // Use centralized canned response helper (handles UI clearing)
                setCannedResponse(speech)
            } else if context.actionType == "stop_game" {
                // Generate "How was that?" style response for game quit
                AppLogger.openAI("🎯 CALL B: Generating stop game response")

                _ = context.gameContextSnapshot.sentimentTargetGame
                let speech = "How was that? Want something similar?"

                // Store snapshot for potential follow-up conversation about the stopped game
                lastStopGameSnapshot = context.gameContextSnapshot
                lastStopGameTimestamp = Date()

                AppLogger.openAI("✅ CALL B: Generated stop game response: \(speech)")

                // Use centralized canned response helper (handles UI clearing)
                setCannedResponse(speech)
            } else if isLaunchCommand(context.jsonCommand) && !isInputCommand(context.jsonCommand) && !context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") {
                // For direct game launches (not from search results), skip the placeholder response since we generate responses
                // after the game actually launches and CurrentGameService is updated
                AppLogger.openAI("⏭️ CALL B: Skipping placeholder response for direct game launch - response will be generated after media.started")
                
                // Store context for deferred response generation
                pendingContext = context
                pendingExecutionResult = executionResult
                pendingApiKey = apiKey
                
                // Start timeout for fallback response
                Task {
                    if TimingConfig.fallbackResponseDelay > 0 {
                        try? await Task.sleep(nanoseconds: TimingConfig.fallbackResponseDelay)
                        await MainActor.run {
                            self.provideFallbackResponse()
                        }
                    }
                }
                
                coolUncleResponse = "" // Empty response for all game launches
            } else if isLaunchCommand(context.jsonCommand) && !isInputCommand(context.jsonCommand) && context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") {
                // CRITICAL FIX: For recommendation launches (from search results), also skip Call B and wait for media.started
                AppLogger.openAI("⏭️ CALL B: Skipping response for recommendation launch - response will be generated after media.started")
                
                // Store context for deferred response generation
                pendingContext = context
                pendingExecutionResult = executionResult
                pendingApiKey = apiKey
                
                // Start timeout for fallback response
                Task {
                    if TimingConfig.fallbackResponseDelay > 0 {
                        try? await Task.sleep(nanoseconds: TimingConfig.fallbackResponseDelay)
                        await MainActor.run {
                            self.provideFallbackResponse()
                        }
                    }
                }
                
                coolUncleResponse = "" // Empty response - wait for media.started
            } else {
                AppLogger.emit(type: .standard, content: "🐛 RANDOM LAUNCH DEBUG: Fell through to normal Call B generation - actionType='\(context.actionType ?? "nil")'")
                AppLogger.openAI("🎯 CALL B: Generating Cool Uncle response with action context")
                context = try await executeCallB_SpeechGeneration(context: context, executionResult: executionResult, apiKey: apiKey)
                
                // Legacy retry system cleanup removed - optimized search handles internally
                
                guard let speech = context.coolUncleResponse else {
                    throw OpenAIServiceError.emptyResponse
                }
                
                coolUncleResponse = speech
                AppLogger.openAI("✅ CALL B: Generated speech: \(speech)")
                AppLogger.openAI("   Response Theme: \(context.responseTheme ?? "unknown")")
            }

            // NOTE: Call C (sentiment analysis) is now handled universally by CallCDispatchService
            // All user utterances are automatically queued for Call C processing with intelligent timing
            
        } catch is CancellationError {
            // User-initiated cancellation - clean exit without error
            AppLogger.standard("✅ Operation cancelled by user - exiting cleanly")
            isLoading = false
            isUsingOptimizedSearch = false
            currentSearchStrategy = nil
            pendingContext = nil

            // Don't show error bubble - "Request stopped" bubble was already shown
            // Don't set lastError - this isn't an error condition

        } catch {
            let friendlyError = friendlyErrorMessage(for: error)
            lastError = friendlyError
            AppLogger.openAI("❌ 3-Call flow failed: \(error)")

            // Check for API key / authentication errors (HTTP 401)
            let errorString = String(describing: error)
            if errorString.contains("HTTP 401") || errorString.contains("API key") {
                Task { @MainActor in
                    self.showAPIKeyError = true
                    self.uiStateService?.hideStatus()
                }
            }

            // Check if this is a network error that should trigger retry
            let nsError = error as NSError
            let isNetworkError = (nsError.domain == NSURLErrorDomain) &&
                                 (nsError.code == NSURLErrorTimedOut ||
                                  nsError.code == NSURLErrorNetworkConnectionLost ||
                                  nsError.code == NSURLErrorCannotConnectToHost ||
                                  nsError.code == NSURLErrorCannotFindHost)

            if isNetworkError {
                // Create retry context for this request
                let retryContext = RetryContext(
                    userMessage: userMessage,
                    conversationHistory: conversationHistory,
                    gameContextSnapshot: gameContextSnapshot
                )

                // Notify UI layer to show network error with retry option
                Task { @MainActor in
                    // Set error response to trigger TTS via onChange handler
                    let errorSpeech = "Oh no, I think my brain went offline for a second there"
                    self.coolUncleResponse = errorSpeech

                    // Add network error bubble with retry context
                    chatBubbleService?.addNetworkErrorMessage(friendlyError, retryContext: retryContext)

                    // Hide transient status
                    uiStateService?.hideStatus()
                }
            }
        }
        
        // Clear cache after successful confirm_yes execution
        if threeCallContext?.actionType == "confirm_yes" && lastError == nil && isPendingRecommendationValid() {
            clearPendingRecommendation()
            AppLogger.standard("🔄 Cache cleared after successful confirm_yes execution")
        }
        
        isLoading = false
    }
    
    // MARK: - CALL A: JSON Command Generation with Context
    
    /// CALL A: Generate JSON command with game history + last 15 conversation messages
    /// Temperature: 0.2, response_format: json_object, focused on action determination
    private func executeCallA_JSONGeneration(
        context: ThreeCallContext,
        apiKey: String
    ) async throws -> ThreeCallContext {

        // Notify Call C dispatch service of A/B activity
        CallCDispatchService.shared.notifyABActivity()

        let prompt = buildCallA_JSONPrompt(context: context)

        // Use mini for initial classification (cheaper + faster), other A calls use gpt-4o
        let config = ModelConfig(model: "gpt-4o-mini", temperature: 0.2, maxTokens: 200)
        AppLogger.openAI("🔧 CALL A (Classification): \(config.description)")

        var requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": getConsolidatedCallA_SystemPrompt()],  // CONSOLIDATED: Same prompt for Phase 1 & 2
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"]
        ]

        // Apply config (merges with defaults as needed)
        config.apply(to: &requestBody, defaults: .defaultCallA)
        
        // Generate context description
        let contextDescription = "executeCallA_JSONGeneration"
        
        let response = try await makeOpenAIRequest(callPhase: "A", context: contextDescription, requestBody: requestBody, apiKey: apiKey)
        
        guard let content = extractContentFromResponse(response),
              !content.isEmpty else {
            throw OpenAIServiceError.emptyResponse
        }
        
        // Parse classification response (no commands yet, just action type)
        let (actionType, actionContext) = try parseClassificationResponse(content, context: context)

        // Update context with classification results
        var updatedContext = context
        updatedContext.actionType = actionType
        updatedContext.actionContext = actionContext

        // Queue Call C NOW that we have actionType (Phase 1 path)
        // Uses original GameContextSnapshot from speech time + newly determined actionType
        let callCContext = CallCContext(
            gameContextSnapshot: context.gameContextSnapshot,
            userMessage: context.userMessage,
            conversationHistory: context.conversationHistory,
            actionType: actionType,
            timestamp: Date()
        )
        CallCDispatchService.shared.queueCallC(context: callCContext)
        AppLogger.standard("✅ Call C queued (Phase 1) with actionType: \(actionType ?? "nil")")

        // Route to task-specific execution based on action type
        updatedContext = try await executeTaskSpecificLogic(context: updatedContext, apiKey: apiKey)

        return updatedContext
    }
    
    /// Get specialized system prompt for Call A (JSON command generation)
    private func getCallA_SystemPrompt() -> String {
        return """
        You are a JSON command generator for MiSTer FPGA gaming. Your ONLY job is to determine what action the user wants and output valid JSON-RPC 2.0 commands.
        
        **ABSOLUTE PRIORITY RULE:**
        If user message starts with `[SYSTEM_INTERNAL_SEARCH_RESULTS]`, you MUST:
        1. Check if search results contain any games from the user's avoid list
        2. If ALL search results are in avoid list, return null (let retry system handle)
        3. If suitable games exist (not in avoid list), launch using exact path from search results
        
        **CRITICAL: When user wants to PLAY a game, ALWAYS generate commands, NEVER return null**
        
        **REQUEST TYPES:**

        1. **INFORMATIONAL (return null) - VERY LIMITED:**
           - "How do I do a fireball?" / "What's the story of [game]?" / "When was [game] released?"
           - "Add this to my playlist" / "Mark this as favorite" / "I don't like this"
           - Pure questions about gameplay/game facts, OR marking games (playlist/favorites/dislikes)

        2. **SPECIFIC GAMES (search then launch):**
           - "Play [game name]" / "Let's play Super Mario" / "Launch Zelda"
           - "Let's play it" / "Play it" (when game mentioned in conversation)
           - ALWAYS search for the game first, then launch
           ✅ Search: {"jsonrpc": "2.0", "id": "", "method": "media.search", "params": {"query": "mario", "systems": ["NES"]}}
           ✅ Launch: {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "NES/Mario.nes"}}
           ❌ WRONG: Missing jsonrpc field will cause "missing or invalid jsonrpc field" error

        3. **RANDOM vs RECOMMENDATION - See detailed logic below:**
           - Check "RANDOM vs RECOMMEND — Intent Analysis" section below for complete decision tree
           - "random [SYSTEM] game" ONLY (no genre/mood/adjectives) → action_type: "random"
           - "random [GENRE/MOOD/ADJECTIVE]" → action_type: "recommend"

        4. **DIFFERENT GAME (search alternative):**
           - "different game" / "another game" / "something else"
           - Pick alternative → Search for it

        5. **OTHER:**
           - "Stop the game" → stop command
        
        **ACTION TYPE RULES:**
        - action_type: "search" = Search for specific game before launch
        - action_type: "launch_specific" = User named a specific game (search first then launch)
        - action_type: "random" = Random requests (use "**launch.random:SYSTEM/*")
        - action_type: "recommend" = Game recommendations (auto-launch after search)
        - action_type: "recommend_alternative" = Alternative after rejection
        - action_type: "version_switch" = User wants different version of SAME game (not different game)
        - action_type: "confirm_yes" = User confirms recommendation ("yes", "sure", "do it")
        - action_type: "confirm_no" = User rejects recommendation ("no", "different game")
        - action_type: "confirm_info" = User wants info about recommendation ("tell me about it")
        - action_type: "game_unavailable" = Specific game not found, offering alternative
        - action_type: "alternative" = Alternative game search after rejection
        - action_type: "no_games_on_system" = System has no games installed
        - action_type: "game_not_found" = Specific game not in collection
        - action_type: "refresh_games" = User wants to refresh game index
        - action_type: "stop" = Stop current game
        
        **SMART RECOMMENDATION LOGIC:**
        When user wants recommendations ("recommend me", "suggest", "find me", etc.):
        
        For both types: 
        1. Search for a game NOT in the avoid list (check carefully!)
        2. If search returns games in avoid list, search for something else
        3. Launch with appropriate action_type
        
        **CRITICAL RULE FOR SEARCH RESULTS:**
        When you receive a message starting with `[SYSTEM_INTERNAL_SEARCH_RESULTS]`, this means search results are available. 
        
        FIRST, analyze the "User originally requested:" line to determine intent:
        - If user named a specific game ("Play Mario 3", "Launch Zelda", "Start Street Fighter") → action_type: "launch_specific"
        - If user asked for recommendations ("Find a cat game", "Suggest something", "What should I play") → action_type: "recommend"
        - If user rejected previous game ("Another one", "Different game", "Not that") → action_type: "recommend_alternative"
        
        THEN, You MUST:
        1. Choose the best USA version from the search results
        2. Generate a LAUNCH command using the exact path from search results
        
        ⚠️ CRITICAL PATH USAGE RULE:
        Each numbered line contains a complete, ready-to-use path. Use the ENTIRE path string after "at path:" exactly as written.
        ⚠️ CRITICAL: Do NOT modify, truncate, or "clean up" the path.
        ⚠️ FAILURE EXAMPLE: AI truncated "Arcade/_alternatives/_Marvel Super Heroes Vs. Street Fighter/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra"
        ⚠️ to "Arcade/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra" → LAUNCH FAILED
        ✅ CORRECT: Use the complete path including all /_alternatives/ subdirectories exactly as written.
        The path may contain .zip/ folders and /_alternatives/ subdirectories - this is correct, use it exactly.
        
        3. NEVER respond without launching the game
        4. Use exact path from search results in launch command
        
        If you do not have an example for a command DO NOT make up your own command, instead return null.
        
        **ABSOLUTE RULE: NEVER launch any game without first verifying it exists via search results**
        
        🚨 CRITICAL: You MUST use ONLY these exact action_type values. DO NOT invent new ones:
        - "informational" (questions, playlist/marking requests)
        - "launch_specific" (play specific game)
        - "random" (random game)
        - "recommend" / "recommend_alternative" (AI picks game)
        - "version_switch" (different version of same game)
        - "confirm_yes" / "confirm_no" / "confirm_info" (responding to recommendations)
        - "game_unavailable" / "alternative" / "no_games_on_system" / "game_not_found"
        - "refresh_games" / "stop" / "systems" / "system_not_available"

        You must return a JSON object with this structure:
        {
            "command": {JSON-RPC 2.0 command object} OR null,
            "action_type": ONE OF THE EXACT STRINGS LISTED ABOVE (never invent new types),
            "action_context": "Brief description" OR null
        }
        
        For informational questions, return:
        {
            "command": null,
            "action_type": "informational",
            "action_context": "Informational question for Cool Uncle"
        }
        
        For user-requested specific games (user said "Play Super Mario World"), return:
        {
            "command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "SNES/Super Mario World.sfc"}},
            "action_type": "launch_specific",
            "action_context": "Launching Super Mario World"
        }
        
        For AI-recommended games, return:
        {
            "command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "SNES/Super Mario World.sfc"}},
            "action_type": "recommend",
            "action_context": "Recommended Super Mario World"
        }
        
        For alternative recommendations (user rejected previous), return:
        {
            "command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "SNES/Donkey Kong Country.sfc"}},
            "action_type": "recommend_alternative",
            "action_context": "Alternative recommendation: Donkey Kong Country"
        }
        
        For random game requests, return:
        {
            "command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "**launch.random:SNES/*"}},
            "action_type": "random",
            "action_context": "Launching random SNES game"
        }

        For unavailable system requests, return:
        {
            "command": null,
            "action_type": "system_not_available",
            "action_context": "Atari Lynx"
        }

        NOTE: For system_not_available, action_context should contain ONLY the system name (e.g., "Atari Lynx", "PlayStation", "Jaguar")

        Valid JSON-RPC methods:
        - "media.search": Search for specific games
        - "launch": Launch specific game or random game  
        - "stop": Quit current game
        - "systems": List available systems
        
        Focus on user intent. Be decisive about actions.
        """
    }
    
    /// Filter conversation history to exclude ALL search results - each search starts fresh
    private func filterToLatestSearchOnly(_ history: [ChatMessage]) -> [ChatMessage] {
        // Always exclude ALL search results to prevent stale contamination
        // Each search should start with clean context
        return history.filter { !$0.content.contains("[SYSTEM_INTERNAL_SEARCH_RESULTS]") }.suffix(5)
    }
    
    /// Build context-aware prompt for Call A with caching optimization
    private func buildCallA_JSONPrompt(context: ThreeCallContext) -> String {
        // CACHE OPTIMIZATION: Build static content first, dynamic content last

        // Get conversation context, excluding ALL search results to prevent contamination
        let recentHistory = Array(context.conversationHistory.suffix(15))
        let filteredHistory = filterToLatestSearchOnly(recentHistory)
        let conversationContext = filteredHistory.isEmpty ? "" :
            "\n\nRecent conversation:\n" + filteredHistory.map { "\($0.role): \($0.content)" }.joined(separator: "\n")

        // Get recently played games to avoid in recommendations
        let avoidDays = UserDefaults.standard.integer(forKey: "avoidGamesDays") == 0 ? 7 : UserDefaults.standard.integer(forKey: "avoidGamesDays")
        let recentGames = UserGameHistoryService.shared.getRecentlyPlayedGames(days: avoidDays)

        // Log state machine info
        AppLogger.verbose("🎯 CALL A Context - Ready")
        AppLogger.verbose("🎯 CALL A Context - Original query: \(context.originalSearchQuery ?? "None")")
        AppLogger.verbose("🎯 CALL A Context - Previous failure: \(context.previousFailureReason ?? "None")")
        AppLogger.verbose("🎯 CALL A Context - Recent games to avoid (\(recentGames.count) games): \(recentGames.isEmpty ? "None" : recentGames.joined(separator: ", "))")

        // CACHE OPTIMIZATION: Dynamic context first (changes slowly), task instruction last (stable)
        var prompt = buildCallA_DynamicContent(context: context, conversationContext: conversationContext)

        // Add task instruction at the very end for maximum cache hits
        prompt += "\n\n"
        prompt += buildCallA_StaticContent(context: context, recentGames: recentGames)

        return prompt
    }

    /// Build static content that can be cached (system prompts, action strategies, etc.)
    private func buildCallA_StaticContent(context: ThreeCallContext, recentGames: [String]) -> String {
        // All boilerplate moved to system prompt for caching
        // Only include phase-specific task instructions here

        if context.actionType == nil {
            // Phase 1: Intent classification
            return buildPhase1_IntentDetection(context: context)
        } else {
            // Phase 2: Action-specific strategies
            return buildCallA_Phase2Strategy(context: context, recentGames: recentGames)
        }
    }

    /// Build dynamic content that changes per request (placed at end for cache efficiency)
    private func buildCallA_DynamicContent(context: ThreeCallContext, conversationContext: String) -> String {
        // Get current game session context
        let sessionContext: String
        if let currentGame = context.gameContextSnapshot.currentGame,
           let duration = context.gameContextSnapshot.sessionDurationMinutes {
            sessionContext = "\n\nCurrent session: \(currentGame) (playing for \(duration) minutes)"
        } else if let currentGame = context.gameContextSnapshot.currentGame {
            sessionContext = "\n\nCurrent session: \(currentGame) (just started)"
        } else {
            sessionContext = "\n\nCurrent session: No game running"
        }

        // Build pending recommendation context
        let pendingContext: String
        if let _ = pendingRecommendationCommand,
           let game = pendingRecommendationGameName,
           let time = pendingRecommendationTimestamp {
            let secondsAgo = Int(Date().timeIntervalSince(time))
            pendingContext = """
            \n\n**PENDING RECOMMENDATION** (cached \(secondsAgo) seconds ago):
            Game ready to launch: "\(game)"
            User hasn't confirmed yet - waiting for response
            """
        } else {
            pendingContext = ""
        }

        // Dynamic content ordered for caching: stable first, user request last
        return """
        📋 AVAILABLE SYSTEMS: \(context.availableSystems.joined(separator: ", "))
        (Map user slang to these IDs. Example: "Super Nintendo"→SNES)

        User's game preferences:
        \(context.gamePreferences)\(conversationContext)\(sessionContext)\(pendingContext)

        User request: "\(context.userMessage)"

        🚨 CRITICAL: Game preferences do NOT change intent classification.
        "Can I play [disliked game]?" is STILL launch_specific, NOT informational.
        Preferences only affect GENERATE phase (search results, alternatives).
        """
    }

    /// Build GENERATE pattern: action-specific strategies
    private func buildCallA_Phase2Strategy(context: ThreeCallContext, recentGames: [String]) -> String {
        var prompt = ""

        switch context.actionType {
            case "launch_specific":
                prompt += buildLaunchSpecificStrategy(context: context, recentGames: recentGames)
            case "recommend":
                // Check if this is a yolo search recommendation
                if context.recommendationSource == "yolo" {
                    // Yolo search results - use proven game unavailable strategy that MUST pick
                    prompt += buildGameUnavailableStrategy(context: context, recentGames: recentGames)
                } else {
                    // Recommendation logic handled in executeTaskSpecificPrompt() -> buildRecommendPrompt()
                    break
                }
            case "recommend_confirm":
                // Check if this is a yolo search recommendation
                if context.recommendationSource == "yolo" {
                    // Yolo search results - use proven game unavailable strategy that MUST pick
                    prompt += buildGameUnavailableStrategy(context: context, recentGames: recentGames)
                } else {
                    // For recommend_confirm with search results, we need to continue the search (not launch)
                    // This will be handled by executeTaskSpecificPrompt
                    break
                }
            case "recommend_alternative":
                // Check if this is a yolo search recommendation
                if context.recommendationSource == "yolo" {
                    // Yolo search results - use proven game unavailable strategy that MUST pick
                    prompt += buildGameUnavailableStrategy(context: context, recentGames: recentGames)
                } else {
                    // Now handled by optimized recommend system
                    break
                }
            case "game_unavailable":
                prompt += buildGameUnavailableStrategy(context: context, recentGames: recentGames)
            case "random":
                prompt += buildRandomStrategy(context: context)
            default:
                // Error: Unknown action type should not reach here with optimized paths
                AppLogger.emit(type: .error, content: "❌ UNKNOWN ACTION TYPE: \(context.actionType ?? "nil") - this should not happen in optimized-only system")
                prompt += """

                **ERROR**: Unknown action type '\(context.actionType ?? "nil")'. All action types should use optimized search paths.
                Return: {"command": null, "action_type": null, "action_context": "Unknown action type error"}
                """
        }

        return prompt
    }

    /// CONSOLIDATED Call A system prompt - replaces both getCallA_SystemPrompt() and getTaskSpecificSystemPrompt()
    /// Used for BOTH patterns: CLASSIFY (action_type) and GENERATE (commands)
    /// Enables 80-90% cache hit rate (vs 0% with two different system prompts)
    private func getConsolidatedCallA_SystemPrompt() -> String {
        return """
        You generate JSON responses for Cool Uncle's MiSTer FPGA gaming system.

        THREE RESPONSE PATTERNS (you'll be told which to use):

        PATTERN A: CLASSIFY (intent only - don't validate if requests are possible)
        {"action_type": "action_name", "action_context": "brief description"}

        CLASSIFY identifies WHAT user wants. GENERATE creates commands after validation.

        PATTERN B: COMMAND (utilities)
        {"command": {"jsonrpc": "2.0", "id": "", "method": "...", "params": {...}}, "action_type": "...", "action_context": null}

        PATTERN C: SEARCH (games)
        {"searches": ["keyword1", "keyword2", "keyword3"], "target_game": "description", "system": "SYSTEM"}

        ## CRITICAL: PRONOUN RESOLUTION ("that game", "it", "this")

        When user says "that game", "it", "this", "play it", "let's play that":

        **PRIORITY ORDER:**
        1. **MOST RECENT conversation mention** (game Cool Uncle just talked about) ← HIGHEST PRIORITY
        2. Current session game (game currently playing) ← Lower priority

        **EXAMPLES:**
        - User: "What was the last NES game in 1995?" → Cool Uncle: "Wario's Woods"
        - User: "Let's play that game" → "that game" = **Wario's Woods** (just mentioned) ✅
        - NOT Dragon Warrior IV (currently playing) ❌

        - User: "Tell me about Street Fighter II" → Cool Uncle: "It's a legendary fighter..."
        - User: "Play it" → "it" = **Street Fighter II** (just discussed) ✅

        **WHY:** If user wanted the current game, they'd say "continue" or "keep playing", not "that game".

        ## PATTERN C: SEARCH TERM GENERATION (for recommendations)

        **KEYWORD EXTRACTION RULES:**
        - Use distinctive words from game titles that appear in ROM names
        - Single words work best ("mario", "zelda", "tetris", "sonic")
        - Avoid common words like "the", "an", "game"
        - Consider MAME romset names: "sf2", "mk", "ddragon", etc.

        🚨 POPULARITY/QUALITY DESCRIPTORS - MENTAL MODEL:

        When user requests obscure/hidden gem/deep cut/underrated games:

        **WHAT THEY MEAN**:
        - Games that were NOT mainstream mega-hits during their era
        - Avoid "top 50" franchises (Mario, Sonic, Zelda, Street Fighter, Final Fantasy, Mega Man main series)
        - Lesser-known titles that critics/fans/YouTubers appreciate
        - Commercial failures that gained cult status years later
        - Japan-only releases or late lifecycle releases

        **DESCRIPTOR KEYWORDS TO RECOGNIZE**:
        - "obscure", "hidden gem", "deep cut", "underrated", "cult classic"
        - "sleeper hit", "overlooked", "forgotten", "not in top 50"
        - "not popular", "under the radar", "lesser known"

        **HOW TO HANDLE - THINK OF ACTUAL OBSCURE GAME NAMES**:

        🎯 CRITICAL: Search uses LITERAL STRING MATCHING on ROM filenames.
        You MUST think of actual obscure game title keywords that match ROM filenames.

        DO NOT use generic words like "quest", "adventure", "battle" - these are NOT game titles.
        DO think of actual less-popular game names from your gaming knowledge.

        **OBSCURE GAME NAME EXAMPLES**:
        These are some, but not all examples of obscure game titles. Use this list to calibrate your thinking.
        
        **NES obscure titles**:
        Some NES obscure titles:
        - Crystalis, Faxanadu, StarTropics, Nightshade, Metal Storm
        - Little Samson, Vice, Shatterhand, Power Blade, Guardian Legend
        - Journey Silius, Gremlins, Magic Scheherazade

        Some Genesis obscure titles:
        - Ranger X, Alien Soldier, Crusader Centy, Landstalker, Alisia Dragoon
        - Rocket Knight, Herzog Zwei, Beyond Oasis, Ristar, Gunstar Heroes

        Some SNES obscure titles:
        - Demon Crest, Actraiser, Soul Blazer, Zombies Neighbors, Metal Warriors
        - Lufia, Blackthorne, Lost Vikings, EVO: The Search for Eden, Brandish

        **STRATEGY**:
        - Think of 3 obscure games you know from that era/system and genre if specified by the user
        - Use the most distinctive KEYWORD from each title

        **COMBINED DESCRIPTOR + GENRE**:
        - "hidden gem puzzle game" → Think of obscure puzzle games → ["bombuzal", "klax", "plotting"]
        - "deep cut platformer" → Think of non-Mario/Sonic platformers → ["rocket", "ristar", "aero"]

        **RECOMMENDATION EXAMPLES:**
        - "Recommend puzzle game" → Think: Tetris, Dr. Mario, Columns → ["tetris", "mario", "columns"]
        - "SNES fighting game" → Think: Street Fighter II, Mortal Kombat, Fatal Fury → ["street", "mortal", "fatal"] (system: "SNES")
        - "Genesis racing" → Think: Road Rash, Sonic racing, OutRun → ["road", "sonic", "outrun"] (system: "Genesis")
        - "Recommend RPG" → Think: Final Fantasy, Dragon Quest, Chrono Trigger → ["final", "dragon", "chrono"]
        - "Action game" → Think: Contra, Mega Man, Castlevania → ["contra", "mega", "castle"]

        🚨 CRITICAL: These examples show the THOUGHT PROCESS, not a list to copy.
        Use your actual gaming knowledge to think of diverse obscure titles.

        **DEMO/HOMEBREW EXAMPLES:**
        - "Play a demo" or "NES demo" → Think: Popular demoscene releases, contest winners → ["demo", "homebrew", "hopes"]
        - "Show me demos" → Think: System-specific demos (Future Crew, Fairlight, Kefrens) → ["future", "fair", "demo"]
        - Consider famous demos: "second reality", "state of the art", "eon" → ["second", "state", "eon"]

        **SYSTEM FIELD IN JSON:**
        - Map user slang to canonical IDs from Available systems list
        - "Super Nintendo" → "SNES", "PlayStation" → "PSX", etc.
        - If no system mentioned, use null

        ## CALL A PATTERN: CLASSIFY

        AUTHORIZED ACTION TYPES:
        - save_state, load_state, stop_game, menu, refresh_games (utility commands)
        - recommend, random, launch_specific, version_switch (game commands)
        - informational (no command needed)
        - confirm_yes, confirm_no, confirm_info (when pending recommendation exists)
        - recommend_alternative (completely different game, not version switch)
        - system_not_available (ONLY when user mentions a system with NO specific game, AND system NOT in 📋)

        SYSTEM AVAILABILITY CHECK:

        When user mentions a system/console, use fuzzy matching to validate it against 📋 AVAILABLE SYSTEMS.

        Fuzzy matching process:
        1. Extract the system name from user's speech (ignore game names)
        2. Use your gaming knowledge to map user's system name to the canonical ID in 📋 AVAILABLE SYSTEMS
           - Apply common abbreviations (N64 = Nintendo64, SMS = MasterSystem, GBA = GBA)
           - Strip manufacturer prefixes ("Sega Saturn" = Saturn, "Sega Genesis" = Genesis)
           - Consider regional names (Mega Drive = Genesis, Super Famicom = SNES)
           - Account for ASR errors ("Omega" often = Amiga)
        3. Check if your mapped canonical ID exists in 📋 AVAILABLE SYSTEMS
        4. If found in 📋 → system is available (use launch_specific, recommend, or random)
        5. If NOT in 📋 → return system_not_available

        CRITICAL: Only strings from 📋 AVAILABLE SYSTEMS are valid in JSON output. User speech must be mapped to 📋 entries.

        Example mappings (use your knowledge for any system):
        - "Sega Saturn" → "Saturn" (strip manufacturer prefix)
        - "N64" → "Nintendo64" (expand abbreviation)
        - "Super Nintendo" → "SNES" (common full name to abbreviation)
        - "SMS" → "MasterSystem" (abbreviation to full name)
        - "Mega Drive" → "Genesis" (regional variant)

        Fuzzy matching examples:
        ✅ User: "Play Paper Mario on N64"
           Extract: "N64" → Map to "Nintendo64" → Check 📋 for "Nintendo64" → Found → launch_specific

        ✅ User: "Can I play Aerobiz on Super Nintendo"
           Extract: "Super Nintendo" → Map to "SNES" → Check 📋 for "SNES" → Found → launch_specific

        ✅ User: "Random SNES game"
           Extract: "SNES" → Already canonical "SNES" → Check 📋 for "SNES" → Found → random

        ✅ User: "Play Jaguar game"
           Extract: "Jaguar" → No alias (use as-is) → Check 📋 for "Jaguar" → NOT found → system_not_available

        Examples showing system-only vs game-specific requests:
        ✅ "play something on NES" → recommend (system + vague "something")
          Step 1: User said "Genesis" �� already canonical, maps to "Genesis"
          Step 2: Check if "Genesis" exists in Available Systems list
          Result: If "Genesis" found → action_type: "random"
          Result: If "Genesis" NOT found → action_type: "system_not_available"

        Unavailable system examples:
        ✅ "Recommend me an Atari Lynx game" + Lynx NOT in available systems
          Step 1: "Atari Lynx" → maps to "AtariLynx" (canonical form)
          Step 2: "AtariLynx" NOT in Available Systems
          Result: action_type: "system_not_available", action_context: "Atari Lynx not available"

        ✅ "I want to play a Jaguar game" + Jaguar NOT in available systems
          Step 1: "Jaguar" → maps to "Jaguar" (canonical form)
          Step 2: "Jaguar" NOT in Available Systems
          Result: action_type: "system_not_available", action_context: "Jaguar not available"

        No system mentioned (normal flow):
        ✅ "Recommend me a puzzle game" + no specific system mentioned
          Step 1: No system reference detected
          Step 2: Skip availability check (no system to check)
          Result: action_type: "recommend" (searches all systems)

        ✅ "Play a random game" + no specific system mentioned
          Step 1: No system reference detected
          Step 2: Skip availability check
          Result: action_type: "random" (random from all systems)

        🚨 SYSTEM NAME RECOGNITION:
        System names are NOT game titles. If user mentions only a system without a specific game → recommend

        Common system name patterns are listed in the SYSTEM AVAILABILITY CHECK section above.

        Examples showing system-only vs game-specific requests:
        ✅ "play something on NES" → recommend (system + vague "something")
        ✅ "find me a Nintendo Entertainment System game" → recommend (system only, no specific game)
        ✅ "play Mega Man on NES" → launch_specific (specific game "Mega Man" mentioned)

        🚨 VAGUE vs SPECIFIC REQUESTS:

        Vague request keywords → recommend:
        - "something", "anything", "a game", "any game"
        - "suggest", "recommend", "find me"

        🚨 RANDOM vs RECOMMEND — Intent Analysis:

        CRITICAL MENTAL MODEL: Is the user asking for...
        - RECKLESS/BLIND dice roll (don't care what I get) → random
        - CURATED choice from Cool Uncle (trust your judgment) → recommend

        🎲 RANDOM (reckless/blind dice roll) - action_type: "random":
        Command: {"method": "launch", "params": {"text": "**launch.random:SYSTEM/*"}}
        🚨 REQUIRES A SYSTEM - random launch cannot work without specifying a system

        ✅ "play a random NES game" → random (blind NES selection, system = NES)
        ✅ "Let's play a random Turbo Grafx 16 game" → random (blind TG16, system = TurboGrafx16)
        ✅ "random Genesis game" → random (blind Genesis, system = Genesis)
        ✅ "play something random on SNES" → random (blind SNES, system = SNES)
        ✅ "hit me with something random from Arcade" → random (blind Arcade, system = Arcade)

        🤖 RECOMMEND (curated selection - Cool Uncle picks) - action_type: "recommend":
        ✅ "random game" → recommend (no system = AI picks system + game)
        ✅ "surprise me" → recommend (pick something interesting/good)
        ✅ "pick something for me" → recommend (use your judgment)
        ✅ "find me something good" → recommend (curated choice)
        ✅ "I want to play a random shmup" → recommend (genre = criteria for curation)
        ✅ "random puzzle game" → recommend (genre = want good puzzle game)
        ✅ "random puzzle game on the NES" → recommend (genre + system = curated)
        ✅ "a random racing game on Genesis" → recommend (genre + system = curated)
        ✅ "play a random chill game" → recommend (mood = criteria)
        ✅ "random NES platformer" → recommend (genre + system = criteria)
        ✅ "hit me with something random" → recommend (no system = curated)

        Selection Criteria = Always Recommend (never random):
        ANY of these trigger recommend (not random):
        - Genres: shmup, puzzle, racing, RPG, platformer, fighting, action, adventure, shooter
        - Moods: chill, intense, relaxing, challenging, fun, exciting
        - Adjectives: good, classic, popular, underrated, weird, hard, easy
        - Game types: demo, arcade, multiplayer, single-player
        - No system specified: "random game" = no system to use for launch.random command

        🎯 TEST HEURISTIC (THE ONLY RULE THAT MATTERS):

        Step 1: Does user mention "random" keyword?
        Step 2: Check for qualifiers:

        A. Has genre/mood/adjective? → ALWAYS action_type: "recommend"
           Examples: "random puzzle game", "random chill NES game", "random platformer on SNES"

        B. Has system but NO genre/mood/adjective? → action_type: "random"
           Examples: "random NES game", "play a random Turbo Grafx 16 game", "random Genesis game"
           Command format: **launch.random:SYSTEM/*

        C. No system specified? → action_type: "recommend"
           Examples: "random game", "surprise me", "hit me with something random"
           Reason: launch.random requires a system - AI must pick both system + game

        🚨 KEY INSIGHT: "random [SYSTEM] game" ONLY (no qualifiers) = action_type: "random"
        🚨 EVERYTHING ELSE with "random" = action_type: "recommend"

        Specific request → launch_specific:
        - Actual game title mentioned (Mario, Zelda, Sonic, Contra, etc.)
        - "this game", "that game", "it" (referring to previously mentioned game)

        🚨 POLITE QUESTIONS = STILL COMMANDS:

        YOUR ROLE: Execute user's gaming intent. Users asking permission are being polite.

        POLITE REQUEST PATTERNS (still launch_specific):
        When user asks permission to play a game, they want it launched:
        ✅ "Can I play [game]?" → launch_specific (polite request to launch)
        ✅ "Could we play [game]?" → launch_specific (polite request to launch)
        ✅ "May I play [game]?" → launch_specific (polite request to launch)
        ✅ "Can we try [game]?" → launch_specific (polite request to launch)

        THE TEST: "Does user want MiSTer to launch/do something?"
        - If YES → Generate command (launch_specific, random, recommend, save_state, etc.)
        - If NO → informational (they just want to talk/learn)

        Examples of COMMANDS (user wants action):
        ✅ "Can I play Space Harrier?" → launch_specific (wants launch)
        ✅ "Could we save the game?" → save_state (wants save)
        ✅ "Can you recommend a puzzle game?" → recommend (wants recommendation)
        ✅ "Play Mario" → launch_specific (direct command)

        Examples of INFORMATIONAL (user wants knowledge):
        ❌ "Tell me about Space Harrier" → informational (wants description)
        ❌ "What's Space Harrier like?" → informational (wants info)
        ❌ "Is Space Harrier good?" → informational (wants opinion)
        ❌ "When was Space Harrier released?" → informational (wants history)

        version_switch vs recommend_alternative:
        - version_switch: SAME game, different platform/region ("arcade version of THIS")
        - recommend_alternative: DIFFERENT game entirely ("play Mortal Kombat instead")

        🚨 VERSION SWITCH TEACHING EXAMPLES:
        Only use version_switch when ALL true:
        1. Game is currently playing
        2. User uses version/variant keywords ("version", "variant", "instead")
        3. User refers to CURRENT game ("this", "it", or context clearly refers to same game)
        4. User does NOT mention a different game name

        Rule: Different game name → launch_specific (NEVER version_switch)

        Examples:
        ❌ "Can we play The Simpsons" → launch_specific (different game name)
        ❌ "Play Mario instead" → launch_specific (different game name)
        ❌ "Can we play Contra in the arcade" → launch_specific (different game name)
        ✅ "Can we play the arcade version" → version_switch (no game name = current game)
        ✅ "English version please" → version_switch (no game name = current game)
        ✅ "Best version of this" → version_switch (explicitly "this" = current game)

        ## CALL A PATTERN: ROM PRIORITY

        Priority order:
        1. [!] Verified Good Dump - HIGHEST PRIORITY
        2. (U), (4), USA, NTSC region
        3. English language
        4. AVOID: [p] Pirate, [b] Bad Dump, [h] Hack, [t] Trainer
        5. DOS games: MT32 version preferred
        6. More complete filenames ("Super Mario Bros 2.nes" > "Mario2.nes")

        Localization: If user uses localized name ("Bare Knuckle"), pick that region's version.

        Path usage: Use ENTIRE path exactly as provided. Do NOT truncate.
        May contain /_alternatives/ and .zip/ - this is correct.

        ## SEARCH CONSTRAINTS

        ROM databases use LITERAL STRING MATCHING only.
        ✅ Search for game TITLE keywords: "tetris", "mario", "street fighter"
        ❌ Do NOT search categories: "puzzle game", "fighting game", "racing"

        ## CRITICAL RULES

        1. ALWAYS include "jsonrpc": "2.0" in JSON-RPC commands
        2. System names: Accept user slang (input), use canonical IDs (JSON output)
        3. Never make up commands - if no example, return null
        4. Search for game NAME keywords, not categories
        5. Avoid recently played games in recommendations
        """
    }

    // MARK: - Phase 1: Clean Intent Detection
    
    /// CLASSIFY pattern: Pure classification - simple intent recognition only
    private func buildPhase1_IntentDetection(context: ThreeCallContext) -> String {
        return """
        **TASK: CLASSIFY** (return PATTERN A)

        Analyze the user request and return action_type + action_context.
        """
    }
    
    // MARK: - GENERATE Pattern: Action-Specific Strategies
    
    /// Strategy for specific game launches - optimized search handles retries internally
    private func buildLaunchSpecificStrategy(context: ThreeCallContext, recentGames: [String]) -> String {
        return """
        **LAUNCH SPECIFIC - PROCESS SEARCH RESULTS**
        
        System has games. Process search results for user's requested game.
        
        If search returned 0 results, optimized search will handle alternative keywords automatically.
        
        If search returned results:
        **CORRECT GAME IDENTIFICATION** (not literal string matching):
        
        **IMPORTANT**: "exact_match" classification means "this is the right game the user wanted" regardless of ROM metadata differences.
        
        Examples of CORRECT game identification:
        - User: "Mario 3" → ROM: "Super Mario Bros. 3 (USA) [!]" = CORRECT GAME ✅
        - User: "Street Fighter" → ROM: "Street Fighter II (U) [!]" = CORRECT GAME ✅
        - User: "Wing Commander 2" → ROM: "Wing Commander II (U)" = CORRECT GAME ✅
        
        **DECISION REQUIREMENT**: When multiple ROMs match the user's request, you MUST pick one and launch it.
        DO NOT ask the user to choose between variants. DO NOT classify as "close match" if any ROM reasonably matches.
        Apply ROM selection criteria and make a confident decision.
        
        **ROM SELECTION PRIORITY** (from picking_a_good_rom.md):
        1. [!] Verified Good Dump = **HIGHEST PRIORITY**
        2. (U), (4), USA, NTSC regions over PAL/European
        3. English language versions over foreign languages
        4. AVOID [p] Pirate, [b] Bad Dump, [h] Hack unless specifically requested
        5. For DOS games: MT32 version preferred over standard
        6. More complete filenames over minimal ones
        
        **FUZZY MATCHING RULES**:
        - Strip ROM metadata for comparison: (USA), (Rev 1), [!], (Europe), etc.
        - Handle abbreviations: Bros = Brothers, 3 = III, 2 = II
        - Regional name awareness: "Streets of Rage" = USA preference, "Bare Knuckle" = Japanese preference
        
        **PROCESS**:
        1. Identify all ROMs that match the requested game (ignoring metadata)
        2. Apply ROM selection priority to pick the best variant
        3. Create LAUNCH command with exact path
        4. Classify as "exact_match" (meaning correct game identified)
        
        ⚠️ CRITICAL PATH USAGE RULE:
        Each numbered line contains a complete, ready-to-use path. Use the ENTIRE path string after "at path:" exactly as written. 
        ⚠️ CRITICAL: Do NOT modify, truncate, or "clean up" the path.
        ⚠️ FAILURE EXAMPLE: AI truncated "Arcade/_alternatives/_Marvel Super Heroes Vs. Street Fighter/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra"
        ⚠️ to "Arcade/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra" → LAUNCH FAILED
        ✅ CORRECT: Use the complete path including all /_alternatives/ subdirectories exactly as written.
        The path may contain .zip/ folders and /_alternatives/ subdirectories - this is correct, use it exactly.
        
        Example: User wanted "All-Star Baseball" and results include:
        27. "All-Star Baseball 2000 (USA) [!]" at path: Nintendo64/All-Star Baseball 2000 (USA)(!).zip/All-Star Baseball 2000 (USA) [!].n64
        
        Use exactly: "Nintendo64/All-Star Baseball 2000 (USA)(!).zip/All-Star Baseball 2000 (USA) [!].n64"
        
        Return: {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "Nintendo64/All-Star Baseball 2000 (USA)(!).zip/All-Star Baseball 2000 (USA) [!].n64"}}}
        """
    }
    
    
    
    /// Strategy for game unavailable scenarios (YOLO search with confirmation)
    private func buildGameUnavailableStrategy(context: ThreeCallContext, recentGames: [String]) -> String {
        return """
        **GAME UNAVAILABLE STRATEGY**
        
        User requested a specific game that wasn't found. YOLO search returned alternative games.
        Pick the best alternative and create a launch command. The system will ask for confirmation.
        
        **CRITICAL**: You MUST select and launch a game from the search results.
        
        **STEPS**:
        **Step 1**: Pick the best alternative game from the search results that matches the user's original request
        **Step 2**: Find best version (prefer USA, then NTSC, then any)  
        **Step 3**: **LAUNCH** - With the exact path. You must pick a game to launch.
        
        ⚠️ **CRITICAL PATH USAGE RULE**:
        Each numbered line contains a complete, ready-to-use path. Use the ENTIRE path string after "at path:" exactly as written. 
        ⚠️ CRITICAL: Do NOT modify, truncate, or "clean up" the path.
        ⚠️ FAILURE EXAMPLE: AI truncated "Arcade/_alternatives/_Marvel Super Heroes Vs. Street Fighter/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra"
        ⚠️ to "Arcade/Marvel Super Heroes Vs. Street Fighter (USA 970625).mra" → LAUNCH FAILED
        ✅ CORRECT: Use the complete path including all /_alternatives/ subdirectories exactly as written.
        The path may contain .zip/ folders and /_alternatives/ subdirectories - this is correct, use it exactly.
        
        **Recently played games - try to avoid making these recommendations first:**
        \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))
        
        **IMPORTANT**: If all games are in the recently played list, you MUST still pick one based on what best matches the user's original request.
        
        **Return format:**
        {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "exact_path"}}, "action_type": "game_unavailable", "action_context": "Found alternative for requested game"}
        """
    }
    
    /// Strategy for random games (direct launch, no search needed)
    private func buildRandomStrategy(context: ThreeCallContext) -> String {
        return """
        **RANDOM STRATEGY**
        
        User wants a random game. Use direct random launch command.
        
        Return: {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "**launch.random:SYSTEM/*"}}, "action_type": "random", "action_context": "Launching random [system] game"}
        
        Use the system from user request or conversation context.
        """
    }





    // MARK: - Legacy Strategy Methods (preserved for compatibility)
    
    /// Build instructions for first search attempt (normal behavior)
    private func buildFirstAttemptInstructions(recentGames: [String]) -> String {
        return """
        Determine the appropriate JSON-RPC command. Examples:
        
        Search: {"jsonrpc": "2.0", "id": "", "method": "media.search", "params": {"query": "mario", "systems": ["NES"]}}
        Launch specific: {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "NES/Super Mario Bros.nes"}}
        Random game: {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "**launch.random:SNES/*"}}
        Stop game: {"jsonrpc": "2.0", "id": "", "method": "stop", "params": {}}
        
        **SEARCH KEYWORDS ONLY**: Use specific game keywords, NOT system names or full titles:
        ✅ CORRECT: {"query": "zelda", "systems": ["SNES"]}, {"query": "mario", "systems": ["SNES"]}
        ❌ WRONG: {"query": "super nintendo", "systems": ["SNES"]}, {"query": "snes game", "systems": ["SNES"]}
        ❌ WRONG: {"query": "The Legend of Zelda: A Link to the Past", "systems": ["SNES"]}
        
        **FOR GAME RECOMMENDATIONS**: Pick a specific popular game franchise to search:
        Examples: mario, zelda, metroid, sonic, street fighter, final fantasy, mega man, castlevania
        
        **5-STEP VALIDATION PROCESS:**
        If user message starts with "[SYSTEM_INTERNAL_SEARCH_RESULTS]":
        
        **Step 1**: Think of the best game from search results
        **Step 2**: If search returned 0 results, return: {"command": null, "error": "stopped at step 2 because search for '[keyword]' returned no games"}
        **Step 3**: Find best version (prefer USA, then NTSC, then any version)
        **Step 4**: Check if chosen game is in avoid list below - if YES, return: {"command": null, "error": "stopped at step 4 because [game name] matched avoid list"}
        **Step 5**: Create launch command with exact path
        
        🚨 **AVOID LIST** - These games are FORBIDDEN:
        \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))
        """
    }
    
    /// Build instructions for second search attempt (avoid top 20 popular games)
    private func buildSecondAttemptInstructions(recentGames: [String], originalQuery: String?, failureReason: String?, failedKeywords: [String] = []) -> String {
        let failureContext = failureReason ?? "all search results were in the avoid list"
        let queryContext = originalQuery ?? "previous search"
        
        let failedKeywordWarning = failedKeywords.isEmpty ? "" : 
            "\n\n🚨 DO NOT SEARCH FOR THESE KEYWORDS AGAIN (returned no games): \(failedKeywords.joined(separator: ", "))"
        
        return """
        **SEARCH ATTEMPT 2 - AVOID TOP 20 POPULAR GAMES**
        
        Previous search for "\(queryContext)" failed because: \(failureContext)\(failedKeywordWarning)
        
        Your task: Find a LESS POPULAR game that avoids mainstream franchises.
        
        **SEARCH KEYWORDS ONLY**: Use keywords, NOT full game titles (ROMs are named differently):
        ✅ CORRECT: {"query": "actraiser", "systems": ["SNES"]}
        ❌ WRONG: {"query": "ActRaiser (USA)", "systems": ["SNES"]}
        
        **AVOID THESE TOP 20 POPULAR FRANCHISES:**
        - Mario (Super Mario, Mario Kart, etc.)
        - Zelda (Legend of Zelda series)  
        - Metroid, Sonic, Final Fantasy, Street Fighter, Mega Man
        - Castlevania, Contra, Donkey Kong, Pac-Man, Tetris
        - Pokemon, Kirby, Star Fox, F-Zero, Chrono Trigger/Cross
        - Secret of Mana, Super Smash Bros, Dragon Quest
        
        **5-STEP VALIDATION PROCESS:**
        If user message starts with "[SYSTEM_INTERNAL_SEARCH_RESULTS]":
        
        **Step 1**: Think of the best lesser-known game from search results
        **Step 2**: If search returned 0 results, return: {"command": null, "error": "stopped at step 2 because search for '[keyword]' returned no games"}
        **Step 3**: Find best version (prefer USA, then NTSC, then any version)
        **Step 4**: Check if chosen game is in avoid list below - if YES, return: {"command": null, "error": "stopped at step 4 because [game name] matched avoid list"}
        **Step 5**: Create launch command with exact path
        
        🚨 **AVOID LIST** - These games are FORBIDDEN:
        \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))
        """
    }
    
    /// Build instructions for third search attempt (processing ALL games from generic search)
    private func buildThirdAttemptInstructions(recentGames: [String], originalQuery: String?, failedKeywords: [String] = [], rejectedGames: [String] = []) -> String {
        let _ = originalQuery ?? "previous searches"
        
        // Combine recent games with rejected games for complete avoid list
        var avoidList = recentGames
        for rejectedGame in rejectedGames {
            if !avoidList.contains(rejectedGame) {
                avoidList.append(rejectedGame)
            }
        }
        
        return """
        **FINAL GAME SELECTION FROM ALL AVAILABLE GAMES**
        
        Previous searches failed. You now have ALL games available on the system.
        Pick the best game that satisfies the user's original request.
        
        **CRITICAL**: This is the FINAL attempt. You MUST select and launch a game.
        
        **SELECTION PROCESS:**
        If user message starts with "[SYSTEM_INTERNAL_SEARCH_RESULTS]":
        
        **Step 1**: Review ALL games and pick the best match for user's request
        **Step 2**: If somehow no games (shouldn't happen), return error
        **Step 3**: Find best version (prefer USA, then NTSC, then any)
        **Step 4**: Check avoid list - BUT if ALL games are in avoid list, STILL PICK ONE
        **Step 5**: Create launch command with exact path
        
        **IMPORTANT FALLBACK RULE**:
        If every single game is in the avoid list, you MUST still pick one based on:
        - What best matches the user's original request
        - What they might enjoy based on their preferences
        - Pick the least recently played if possible
        
        **AVOID LIST (prefer to avoid but MUST pick one if all are in list):**
        \(avoidList.isEmpty ? "None" : "- " + avoidList.joined(separator: "\n        - "))
        
        **Already rejected in previous attempts:**
        \(rejectedGames.isEmpty ? "None" : "- " + rejectedGames.joined(separator: "\n        - "))
        """
    }
    
    /// Build instructions for failure reporting (attempt 3+)
    private func buildFailureReportInstructions() -> String {
        return """
        **SEARCH EXHAUSTED - ALL STRATEGIES FAILED**
        
        All search attempts (specific games, hidden gems, generic search) have been exhausted.
        
        Return null command - no suitable games available that aren't in the avoid list.
        """
    }
    
    /// Parse Call A response to extract command and context
    private func parseCallA_Response(_ content: String) throws -> (jsonCommand: String?, actionType: String?, actionContext: String?) {
        AppLogger.verbose("🔍 CALL A RAW RESPONSE: \(content)")
        
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.openAI("❌ CALL A JSON PARSE FAILED - Raw content: \(content)")
            throw OpenAIServiceError.parseError("Invalid JSON response from Call A - Raw: \(content)")
        }
        
        AppLogger.verbose("✅ CALL A JSON PARSED: \(json)")
        
        // Check if AI returned null (informational question)
        if let commandValue = json["command"], commandValue is NSNull {
            AppLogger.openAI("💬 CALL A: Detected null command - informational question or search failure")
            let actionContext = json["action_context"] as? String ?? "Informational question for Cool Uncle"
            return (jsonCommand: nil, actionType: nil, actionContext: actionContext)
        }
        
        // Extract command object and metadata
        guard let commandObject = json["command"] as? [String: Any] else {
            AppLogger.openAI("❌ CALL A: Missing command object")
            throw OpenAIServiceError.parseError("Missing command object in Call A response")
        }
        
        // Convert command object to JSON string
        let commandData = try JSONSerialization.data(withJSONObject: commandObject)
        let jsonCommand = String(data: commandData, encoding: .utf8) ?? ""
        
        // Extract metadata from response structure
        let actionType = json["action_type"] as? String
        let actionContext = json["action_context"] as? String
        
        return (jsonCommand: jsonCommand, actionType: actionType, actionContext: actionContext)
    }
    
    /// Parse pure classification response (no commands, just action type)
    /// Applies session-based transformations: recommend → recommend_confirm when game session ≥ 2 minutes
    private func parseClassificationResponse(_ content: String, context: ThreeCallContext) throws -> (actionType: String?, actionContext: String?) {
        #if DEBUG
        print("🔍 ENTERING parseClassificationResponse - checking timer logic")
        #endif
        AppLogger.verbose("🔍 CLASSIFICATION RAW RESPONSE: \(content)")
        
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.openAI("❌ CLASSIFICATION JSON PARSE FAILED - Raw content: \(content)")
            throw OpenAIServiceError.parseError("Invalid JSON response from classification - Raw: \(content)")
        }
        
        AppLogger.verbose("✅ CLASSIFICATION JSON PARSED: \(json)")
        
        var actionType = json["action_type"] as? String
        let actionContext = json["action_context"] as? String

        #if DEBUG
        print("🔍 Parsed actionType: \(actionType ?? "nil")")
        print("🔍 Session duration: \(context.gameContextSnapshot.sessionDurationMinutes ?? -1) minutes")
        print("🔍 Current game: \(context.gameContextSnapshot.currentGame ?? "none")")
        #endif

        // Map common AI-invented action types to valid ones (graceful fallback)
        if actionType == "add_to_playlist" || actionType == "add_to_favorites" || actionType == "mark_as_disliked" {
            AppLogger.openAI("🔄 Mapping '\(actionType ?? "")' → 'informational' (AI invented invalid type)")
            actionType = "informational"
        }

        // Handle recommend_alternative when there's a pending recommendation (rejection)
        if actionType == "recommend_alternative" && isPendingRecommendationValid() {
            #if DEBUG
            print("🔄 User rejected pending recommendation - clearing cache for new search")
            #endif
            clearPendingRecommendation()
            // Keep as recommend_alternative to search for new game
        }
        
        // Apply session-based transformation: recommend/recommend_alternative → recommend_confirm when game session ≥ settings minutes
        if (actionType == "recommend" || actionType == "recommend_alternative"),
           let sessionDurationMinutes = context.gameContextSnapshot.sessionDurationMinutes {
            
            // Get the threshold from settings (0 = never ask for confirmation)
            let confirmThreshold = UserDefaults.standard.integer(forKey: "recommendConfirmMinutes")
            let shouldAskConfirmation = confirmThreshold > 0 && sessionDurationMinutes >= confirmThreshold
            
            if shouldAskConfirmation {
                let originalType = actionType
                actionType = "recommend_confirm"
                #if DEBUG
                print("Switching \(originalType ?? "unknown") -> Recommend_confirm after \(sessionDurationMinutes) minute timer expired")
                #endif
            }
        }
        
        // Handle orphaned confirmations (confirm_yes/confirm_info with no pending recommendation)
        if (actionType == "confirm_yes" || actionType == "confirm_info") && !isPendingRecommendationValid() {
            #if DEBUG
            print("🔄 Orphaned confirmation detected - treating as informational")
            #endif
            actionType = "informational"
        }
        
        
        return (actionType: actionType, actionContext: actionContext)
    }
    
    /// Execute task-specific logic based on classification result
    private func executeTaskSpecificLogic(context: ThreeCallContext, apiKey: String) async throws -> ThreeCallContext {
        guard let actionType = context.actionType else {
            throw OpenAIServiceError.parseError("No action type from classification")
        }
        
        // Skip old launch_specific logic when using optimized search
        if actionType == "launch_specific" && useOptimizedLaunchSpecific {
            #if DEBUG
            print("🚀 Skipping old launch_specific logic - using optimized path")
            #endif
            return context
        }

        // Skip old recommend logic when using optimized search
        if (actionType == "recommend" || actionType == "recommend_alternative") && useOptimizedRecommend {
            #if DEBUG
            print("🚀 Skipping old recommend logic - using optimized path")
            #endif
            return context
        }
        
        var updatedContext = context
        
        switch actionType {
        // Utility commands - generate commands immediately  
        case "save_state":
            updatedContext.jsonCommand = """
            {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "**input.keyboard:{lalt+f1}"}}
            """
            
        case "load_state":
            updatedContext.jsonCommand = """
            {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "**input.keyboard:{f1}"}}
            """
            
        case "stop_game":
            updatedContext.jsonCommand = """
            {"jsonrpc": "2.0", "id": "", "method": "stop", "params": {}}
            """
            
        case "menu":
            updatedContext.jsonCommand = """
            {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "**input.keyboard:{f12}"}}
            """
            
        case "refresh_games":
            updatedContext.jsonCommand = """
            {"jsonrpc": "2.0", "id": "", "method": "media.index"}
            """
            updatedContext.actionContext = "Refreshing game database"
            
        // Game commands - need task-specific prompts
        // NOTE: version_switch removed from this list - it uses optimized VersionSwitchStrategy routing in processUserMessage
        case "search", "recommend", "recommend_confirm", "recommend_alternative", "game_unavailable", "random", "launch_specific", "alternative":
            updatedContext = try await executeTaskSpecificPrompt(context: updatedContext, apiKey: apiKey)

        // version_switch handled by optimized routing (VersionSwitchStrategy) - skip legacy prompt system
        case "version_switch":
            // No action needed - routing happens in processUserMessage before this point
            break
            
        // Confirmation commands - need special handling
        case "confirm_yes", "confirm_no", "confirm_info":
            updatedContext = try await executeConfirmationAction(context: updatedContext, apiKey: apiKey)
            
        // Informational - no command needed
        case "informational":
            updatedContext.jsonCommand = nil

        // System not available - no command needed (informational response only)
        case "system_not_available":
            updatedContext.jsonCommand = nil

        default:
            // Log the unknown action type for debugging
            AppLogger.openAI("❌ UNKNOWN ACTION TYPE: '\(actionType)' - stopping ABC flow gracefully")

            // Set friendly error message for user
            updatedContext.coolUncleResponse = "Wow, this is embarrassing, but something went wrong with that command. Please use the Report Issue button to share this with the app author so we can fix it!"
            updatedContext.jsonCommand = nil  // Stop execution

            // Return gracefully instead of throwing exception
        }

        return updatedContext
    }
    
    /// Execute confirmation action - handle confirm_yes, confirm_no, confirm_info
    private func executeConfirmationAction(context: ThreeCallContext, apiKey: String) async throws -> ThreeCallContext {
        var updatedContext = context
        
        switch context.actionType {
        case "confirm_yes":
            if isPendingRecommendationValid(), let cached = pendingRecommendationCommand {
                // Execute the cached command
                updatedContext.jsonCommand = cached
                updatedContext.actionContext = "Launching confirmed game"
                // Cache will be cleared after Call B completes
                AppLogger.standard("✅ Executing cached recommendation")
            } else {
                // Cache expired or missing
                updatedContext.jsonCommand = nil
                updatedContext.actionContext = "No pending recommendation to confirm"
                AppLogger.standard("⚠️ No cache, command ignored: confirm_yes with no pending recommendation (expired or missing)")
            }
            
        case "confirm_no":
            // DEPRECATED: confirm_no should no longer be classified by AI
            // Redirect to recommend_alternative for proper handling
            #if DEBUG
            print("⚠️ DEPRECATED: confirm_no detected - redirecting to recommend_alternative")
            #endif
            clearPendingRecommendation()
            updatedContext.actionType = "recommend_alternative"
            updatedContext.actionContext = "Finding alternative recommendation"
            // Re-execute with the new action type
            return try await executeTaskSpecificLogic(context: updatedContext, apiKey: apiKey)
            
        case "confirm_info":
            // Check if cache is still valid
            if !isPendingRecommendationValid() {
                updatedContext.jsonCommand = nil
                updatedContext.actionContext = "Recommendation expired"
                AppLogger.standard("⚠️ No cache, command ignored: confirm_info but recommendation expired")
            } else {
                // Cache remains for potential future confirmation
                updatedContext.jsonCommand = nil
                updatedContext.actionContext = "Providing game information"
                AppLogger.standard("ℹ️ Providing info about \(pendingRecommendationGameName ?? "cached game")")
            }
            
        default:
            updatedContext.jsonCommand = nil
        }
        
        return updatedContext
    }
    
    /// Execute task-specific prompt for game commands
    private func executeTaskSpecificPrompt(context: ThreeCallContext, apiKey: String) async throws -> ThreeCallContext {
        let prompt = await buildTaskSpecificPrompt(context: context)
        
        let requestBody: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": getConsolidatedCallA_SystemPrompt()],  // CONSOLIDATED: Same prompt for Phase 1 & 2 - ENABLES CACHING
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 4096,
            "temperature": 0.2,
            "response_format": ["type": "json_object"]
        ]
        
        // Generate context with specific action type
        let actionTypeDescription = context.actionType ?? "unknown"
        let contextDescription = "executeTaskSpecificPrompt-\(actionTypeDescription)"
        
        let response = try await makeOpenAIRequest(callPhase: "A", context: contextDescription, requestBody: requestBody, apiKey: apiKey)
        
        guard let content = extractContentFromResponse(response),
              !content.isEmpty else {
            throw OpenAIServiceError.emptyResponse
        }
        
        // Parse command response
        let (jsonCommand, responseActionType, actionContext) = try parseCallA_Response(content)
        
        // Validate JSON-RPC format if we have a command
        if let command = jsonCommand {
            try validateJSONCommand(command)
        }
        
        // SMART PRESERVATION: Handle recommend_confirm preservation logic
        var finalActionType = responseActionType
        var needsSalesPitch = false
        
        if context.actionType == "recommend_confirm" && responseActionType != "recommend_confirm" {
            
            // Check if this is AI retry flow vs new user input
            let isRetryFlow = context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]")
            
            if isRetryFlow {
                // We're in retry/YOLO flow - preserve recommend_confirm for search flow types
                let searchFlowTypes = ["recommend", "recommend_alternative", "launch", "alternative"]
                if searchFlowTypes.contains(responseActionType ?? "") {
                    #if DEBUG
                    print("🔒 Preserving recommend_confirm during retry (AI tried: \(responseActionType ?? "nil"))")
                    #endif
                    finalActionType = "recommend_confirm"
                }
            } else if responseActionType == "informational" {
                // User asking about pending recommendation - keep alive & reset timer!
                #if DEBUG
                print("💬 User asking about recommendation - preserving recommend_confirm & resetting timer")
                #endif
                finalActionType = "recommend_confirm"
                // Reset the 2-minute expiration timer
                pendingRecommendationTimestamp = Date()
                // Flag for sales pitch mode
                needsSalesPitch = true
            } else if responseActionType == "confirm_yes" {
                // User confirmed - let it proceed
                finalActionType = responseActionType
            } else {
                // User making different request - clear and move on
                #if DEBUG
                print("🔄 New user request - clearing recommend_confirm for: \(responseActionType ?? "nil")")
                #endif
                clearPendingRecommendation()
                finalActionType = responseActionType
            }
        }

        // YOLO SEARCH PRESERVATION: Preserve yolo recommendation state regardless of LLM response
        if context.recommendationSource == "yolo" {
            AppLogger.emit(type: .launchRouting, content: "Preserving yolo recommendation state (actionType: \(context.actionType ?? "nil"), LLM tried: \(responseActionType ?? "nil"), jsonCommand: \(jsonCommand != nil ? "present" : "nil"))")
            // Keep original action type (recommend/recommend_confirm) and preserve yolo source
            // BUT allow jsonCommand to be updated with the new launch command from AI
            finalActionType = context.actionType
        }

        var updatedContext = context
        updatedContext.jsonCommand = jsonCommand
        // Use our smart preservation logic
        if let finalActionType = finalActionType {
            updatedContext.actionType = finalActionType
        }
        updatedContext.actionContext = actionContext ?? context.actionContext
        updatedContext.needsSalesPitch = needsSalesPitch
        // Preserve recommendationSource (especially important for yolo searches)
        // updatedContext.recommendationSource stays the same from context
        
        return updatedContext
    }
    
    /// Get system prompt for task-specific execution
    private func getTaskSpecificSystemPrompt() -> String {
        return """
        You are a specialized command generator for MiSTer FPGA gaming. Generate JSON-RPC 2.0 commands based on the specific task type.
        
        **CRITICAL SEARCH CONSTRAINTS (applies to ALL searches)**:
        1. NO SEMANTIC/CATEGORY SEARCH - Only literal string matching against ROM filenames
           - Cannot search for "racing" or "puzzle" as categories
           - Must search for actual game name keywords
        2. ROM VERSION SELECTION - Pick best available version:
           USA → NTSC → World → Europe → Japan → ANY version
           NEVER skip a game because USA version isn't available
        
        You must return a JSON object with this structure:
        {
            "command": {
                "jsonrpc": "2.0",  // REQUIRED - Must be exactly "2.0"
                "id": "",          // REQUIRED - Leave empty (SessionManager fills)
                "method": "...",   // REQUIRED - The API method
                "params": {...}    // REQUIRED - Method parameters
            } OR null,
            "action_type": "action_type", 
            "action_context": "Brief description"
        }
        
        Valid JSON-RPC methods:
        - "media.search": Search for games
          ✅ CORRECT: {"jsonrpc": "2.0", "id": "", "method": "media.search", "params": {"query": "mario", "systems": ["NES"]}}
          ❌ WRONG: Missing jsonrpc field causes ERROR
          
        - "launch": Launch game
          ✅ CORRECT: {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "SNES/Mario.sfc"}}
          ❌ WRONG: Missing jsonrpc field causes ERROR
          
        - "stop": Quit game
          ✅ CORRECT: {"jsonrpc": "2.0", "id": "", "method": "stop", "params": {}}

        **CRITICAL**: EVERY command MUST include "jsonrpc": "2.0" or MiSTer will reject it
        """
    }
    
    /// Build task-specific prompt based on action type
    private func buildTaskSpecificPrompt(context: ThreeCallContext) async -> String {
        let systemsList = context.availableSystems.joined(separator: ", ")
        let avoidDays = UserDefaults.standard.integer(forKey: "avoidGamesDays") == 0 ? 7 : UserDefaults.standard.integer(forKey: "avoidGamesDays")
        let recentGames = await MainActor.run { UserGameHistoryService.shared.getRecentlyPlayedGames(days: avoidDays) }
        
        // Build prompt with caching order: stable first, dynamic last
        guard let actionType = context.actionType else {
            return """
            Available systems: \(systemsList)

            User's game preferences:
            \(context.gamePreferences)

            User request: "\(context.userMessage)"

            **TASK: GENERATE** (return PATTERN B)
            """
        }

        // Base context - ordered for caching efficiency
        let baseContext = """
        Available systems: \(systemsList)

        User's game preferences:
        \(context.gamePreferences)

        User request: "\(context.userMessage)"

        **TASK: GENERATE for \(actionType)** (return PATTERN B/C)
        """
        
        switch actionType {
        case "search":
            // Search action type - treat as recommendation search
            return baseContext + buildRecommendPrompt(recentGames: recentGames, context: context)
            
        case "recommend":
            return baseContext + buildRecommendPrompt(recentGames: recentGames, context: context)
            
        case "recommend_confirm":
            return baseContext + buildRecommendConfirmPrompt(recentGames: recentGames, context: context)
            
        case "random":
            return baseContext + buildRandomPrompt()
            
        case "launch_specific":
            return baseContext + buildLaunchSpecificPrompt()
            
        case "alternative":
            return baseContext + buildAlternativePrompt(recentGames: recentGames)
            
        case "recommend_alternative":
            return baseContext + buildAlternativePrompt(recentGames: recentGames)
            
        case "game_unavailable":
            return baseContext + buildGameUnavailablePrompt(recentGames: recentGames)

        // version_switch now uses optimized search pathway (VersionSwitchStrategy)
        // Routing happens in processUserMessage before reaching this legacy code

        // Legacy - remove later
        // case "confirm_launch":
        //     return baseContext + buildConfirmLaunchPrompt()

        default:
            return baseContext + "\n\nUnknown action type: \(actionType)"
        }
    }
    
    /// Build recommendation prompt with clean step-based logic
    private func buildRecommendPrompt(recentGames: [String], context: ThreeCallContext) -> String {
        // Check if processing search results
        let isProcessingSearchResults = context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]")
        
        if isProcessingSearchResults {
            // Processing search results - optimized search handles retries internally
            return """
            
            **RECOMMENDATION - PROCESS SEARCH RESULTS**
            
            Pick best game from search results and launch it.
            
            **AVOID LIST:**
            \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n                - "))
            
            **PROCESS:**
            1. Pick best game from results (not in avoid list)
            2. Generate launch command with exact path
            
            **If no results or all avoided:** Optimized search will handle alternative strategies automatically
            **If good match:** {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "exact_path"}}, "action_type": "recommend", "action_context": "Launching game"}
            """
        } else {
            // Initial request - generate search
            
            return """
            
            **RECOMMENDATION - GAME SELECTION & SEARCH**
            Generate search based on user request type.

            **AVOID LIST:**
            \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n            - "))

            **DEMO SEARCH STRATEGY:**
            If the user is asking for demos or homebrew games, use this special search pattern:
            - Think of popular demoscene releases for the requested system (contest winners, famous demos)
            - Search for: "[specific demo name]" OR "demo" OR "homebrew"
            - Popular demos to consider: Future Crew demos, Fairlight, Kefrens, Spaceballs, etc.
            - Many ROM collections have demos in folders labeled "demo" or under homebrew sections

            **STANDARD PROCESS:**
            1. Think of specific game titles that match the category requested
            2. Extract searchable keywords from those titles
            3. Generate search command with appropriate query

            **Return:** Search command with keywords from actual game titles
            """
        }
    }
    
    /// Build recommendation confirmation prompt
    /// Used when user has been playing a game for ≥2 minutes and needs confirmation before switching
    private func buildRecommendConfirmPrompt(recentGames: [String], context: ThreeCallContext) -> String {
        // Check if this is processing search results
        if context.userMessage.starts(with: "[SYSTEM_INTERNAL_SEARCH_RESULTS]") {
            // We have search results - pick a game and generate a LAUNCH command
            // The launch will be intercepted and cached by ContentView for confirmation
            return """
            
            **RECOMMENDATION CONFIRMATION - PROCESS SEARCH RESULTS**
            
            You have search results. You have two options, Pick the best game and generate a LAUNCH command, or generate error if the launch command cannot meet the parameters.
            
            
            **5-STEP VALIDATION**:
            **Step 1**: Review search results and pick the best game
            **Step 2**: Find the best version (prefer USA, then NTSC, then any)  // NOTE: May be redundant with system prompt
            **Step 3**: Check against avoid list using fuzzy matching
            **Step 4**: If game is in avoid list, pick another or return error
            **Step 5**: Generate a LAUNCH command with the exact path from search results
            
            🚨 **AVOID LIST** - Games recently played that must be avoided:
            \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))
            
            **CRITICAL: Return format MUST use action_type "recommend_confirm":**
            {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "exact/path/from/search/results.ext"}}, "action_type": "recommend_confirm", "action_context": "Selected [game name] for confirmation"}
            """
        } else {
            // Initial request - generate a search to find games
            return """
            
            **RECOMMENDATION CONFIRMATION TASK**
            
            User is currently playing a game and wants a recommendation but needs confirmation before switching.
            Generate a search command to find games, then you'll pick one for confirmation.
            
            **5-STEP PROCESS**:
            **Step 1**: Think of best game type matching user's request
            **Step 2**: Generate search with appropriate keyword
            **Step 3**: Return search command (results will be processed next)
            
            🚨 **AVOID LIST** - Games recently played that must be avoided:
            \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))
            
            **Return format (SEARCH ONLY):**
            {"command": {"jsonrpc": "2.0", "id": "", "method": "media.search", "params": {"query": "keyword", "systems": ["SYSTEM"]}}, "action_type": "recommend_confirm", "action_context": "Searching for games"}
            """
        }
    }
    
    /// Build random prompt (no avoid list needed)
    private func buildRandomPrompt() -> String {
        return """
        
        **RANDOM TASK**
        
        Generate a random launch command based on user's request.
        
        Extract system from user request and generate random launch command.
        
        **CRITICAL**: The launch command MUST start with TWO asterisks followed by "launch.random:"
        
        **Return format:**
        {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "ASTERISK_ASTERISK_launch.random:SYSTEM/*"}}, "action_type": "random", "action_context": "Launching random game"}
        
        **Example**: Replace ASTERISK_ASTERISK with ** and SYSTEM with actual system name like SNES
        Expected: "**launch.random:SNES/*"
        """
    }
    
    /// Build launch specific prompt (no avoid list needed - user explicitly requested)
    private func buildLaunchSpecificPrompt() -> String {
        return """
        
        **LAUNCH SPECIFIC TASK**
        
        User wants a specific game by name. Generate search command with ONE keyword.
        
        **KEYWORD EXTRACTION RULES:**
        The search is LITERAL STRING MATCHING, not semantic. Extract ONE keyword that will match ROM filenames:
        
        1. REMOVE these (won't be in ROM names):
           - Hyphens, colons, apostrophes, punctuation
           - Years (2000, 2k, 99, etc.)
           - Roman numerals (II, III, IV)
           
        2. SKIP filler words:
           - Articles: "the", "a", "an"
           - Prepositions: "of", "in", "at", "for", "with"
           - Conjunctions: "and", "or", "but"
        
        3. PICK the MOST DISTINCTIVE single word:
           - Sport names are good: "baseball", "football", "hockey"
           - Character names work: "mario", "sonic", "zelda"
           - Unique words: "kombat", "fighter", "dragon"
           - Action words: "battle", "racing", "puzzle"
        
        **Examples showing the process:**
        - "All-Star Baseball 2000" → Remove: hyphen, "2000" → Skip: "All" → Pick: "baseball"
        - "Street Fighter II: Turbo" → Remove: "II", colon → Pick: "fighter" or "street" (both good)
        - "The Legend of Zelda" → Skip: "The", "of" → Pick: "zelda" (franchise name)
        - "Mortal Kombat 3" → Remove: "3" → Pick: "kombat" (more unique than "mortal")
        - "Super Mario World" → Skip: generic "Super", "World" → Pick: "mario"
        - "Gran Turismo 2" → Remove: "2" → Pick: "turismo" or "gran"
        
        **Return format:**
        {"command": {"jsonrpc": "2.0", "id": "", "method": "media.search", "params": {"query": "ONE_KEYWORD", "systems": ["SYSTEM"]}}, "action_type": "launch_specific", "action_context": "Searching for [game name]"}
        """
    }
    
    /// Build confirmation launch prompt (user confirmed they want the recommended game)
    private func buildConfirmLaunchPrompt() -> String {
        return """
        
        **CONFIRM LAUNCH TASK**
        
        User has confirmed they want to launch the game that was previously found and described.
        Look at the conversation history to find what game was recommended and create a launch command for it.
        
        **STEPS**:
        1. Find the game that was recommended in the previous conversation
        2. Create a launch command for that exact game using the path from search results
        3. No need to search again - use the information from previous messages
        
        **Return format:**
        {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "exact_path_from_previous_search"}}, "action_type": "confirm_launch", "action_context": "Launching confirmed game"}
        """
    }
    
    /// Build game unavailable prompt - for YOLO search scenarios requiring confirmation
    private func buildGameUnavailablePrompt(recentGames: [String]) -> String {
        return """

        **GAME UNAVAILABLE TASK**

        User asked for a specific game that couldn't be found. YOLO search found alternatives.
        **CRITICAL**: You MUST select and launch a game from the search results.

        **STEPS**:
        **Step 1**: Pick the best alternative game from the search results
        **Step 2**: Find best version (prefer USA, then NTSC, then any)
        **Step 3**: **LAUNCH** - With the exact path. You must pick a game to launch.

        **Recently played games - try to avoid making these recommendations first:**
        \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))

        **IMPORTANT**: If all games are in the recently played list, you MUST still pick one based on what best matches the user's original request.

        **Return format:**
        {"command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "exact_path"}}, "action_type": "game_unavailable", "action_context": "Found alternative for requested game"}
        """
    }

    // buildVersionSwitchPrompt removed - now uses VersionSwitchStrategy in optimized search path

    /// Build alternative prompt with strict avoid list matching
    private func buildAlternativePrompt(recentGames: [String]) -> String {
        return """
        
        **ALTERNATIVE TASK**
        
        User wants something different from current/recent games.
        
        **5-STEP VALIDATION WITH STRICT FUZZY MATCHING**:
        **Step 1**: Think of game DIFFERENT from recent history (different franchises/genres)
        **Step 2**: Verify search returned results (error if 0 results)
        **Step 3**: Find best version (prefer USA, then NTSC, then any)
        **Step 4**: 🚨 **STRICT FUZZY MATCHING** - Check against avoid list using CORE GAME TITLE:
        - Strip regions: (USA), (JP), (EU), (World), (Europe), (Japan), (NTSC), (PAL)
        - Strip versions: (Rev A), (Beta), (v1.0), (1), (2), (3), (4), (5), numbers in parentheses
        - Strip extensions: .32X, .nes, .sfc, .zip, .chd, .cue, file paths, /...
        - Strip extra text: [!], [h1], [en], [OCS], etc.
        - Must be different from recent games AND different genre/franchise
        - If matches, return: {"command": null, "error": "stopped at step 4 because [core game name] matched avoid list"}
        **Step 5**: Create search command with keyword
        
        🚨 **STRICT AVOID LIST** - Must be different from:
        \(recentGames.isEmpty ? "None" : "- " + recentGames.joined(separator: "\n        - "))
        
        **Return format:**
        {"command": {"jsonrpc": "2.0", "id": "", "method": "media.search", "params": {"query": "keyword", "systems": ["SYSTEM"]}}, "action_type": "alternative", "action_context": "Searching for alternative game"}
        """
    }
    
    /// Infer action context from JSON-RPC command
    private func inferActionContext(from json: [String: Any]) -> String? {
        guard let method = json["method"] as? String else { return nil }
        
        switch method {
        case "media.search":
            if let params = json["params"] as? [String: Any],
               let query = params["query"] as? String,
               let systems = params["systems"] as? [String] {
                return "Searching for '\(query)' on \(systems.joined(separator: ", "))"
            }
            return "Searching for games"
        case "launch":
            if let params = json["params"] as? [String: Any],
               let text = params["text"] as? String {
                if text.contains("launch.random") {
                    // Extract system name from random launch command
                    // Format: "**launch.random:SYSTEM/*"
                    if let systemRange = text.range(of: "launch.random:"),
                       let endRange = text.range(of: "/*", range: systemRange.upperBound..<text.endIndex) {
                        let system = String(text[systemRange.upperBound..<endRange.lowerBound])
                        return "Launching Random \(system) game"
                    }
                    return "Launching Random game"
                } else {
                    return "Launching \(text)"
                }
            }
            return "Launching game"
        case "stop":
            return "Stopping current game"
        case "systems":
            return "Listing available systems"
        default:
            return "Executing \(method)"
        }
    }
    
    // MARK: - CALL B: Cool Uncle Speech Generation with Action Context
    
    /// CALL B: Generate Cool Uncle response knowing what action was taken + last 25 messages
    /// Temperature: 0.8, personality-focused, no JSON requirements
    private func executeCallB_SpeechGeneration(
        context: ThreeCallContext,
        executionResult: String,
        apiKey: String
    ) async throws -> ThreeCallContext {

        // Update status to show AI response generation
        Task { @MainActor in
            uiStateService?.showStatus("Cool Uncle is generating a response...")
        }

        // Notify Call C dispatch service of A/B activity
        await CallCDispatchService.shared.notifyABActivity()

        // Create mutable context for flag management
        var workingContext = context

        // Build prompt (may include ModelConfig override)
        let (prompt, configOverride) = await buildCallB_SpeechPrompt(context: workingContext, executionResult: executionResult)

        // Reset sales pitch flag after it's used in prompt generation
        if workingContext.needsSalesPitch {
            #if DEBUG
            print("🔄 Resetting needsSalesPitch flag after prompt generation")
            #endif
            workingContext.needsSalesPitch = false
        }

        // Apply override or use defaults
        let config = configOverride ?? ModelConfig.defaultCallB

        // Log override usage
        if configOverride != nil {
            AppLogger.openAI("⚙️ CALL B OVERRIDE: \(config.description) for action_type: \(workingContext.actionType ?? "nil")")
        } else {
            AppLogger.openAI("🔧 CALL B DEFAULT: \(config.description)")
        }

        // Removed: CALL B RUNTIME CONTEXT logging - clutters session logs for bug reporting
        // User message already logged as "🗣️ User: ..." and Call B response logged separately

        // Build request body with config-driven parameters
        var requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": getCallB_SystemPrompt()],
                ["role": "user", "content": prompt]
            ]
        ]

        // Apply config (merges with defaults as needed)
        config.apply(to: &requestBody, defaults: .defaultCallB)
        
        let response = try await makeOpenAIRequest(callPhase: "B", context: "executeCallB_SpeechGeneration", requestBody: requestBody, apiKey: apiKey)
        
        guard let content = extractContentFromResponse(response),
              !content.isEmpty else {
            throw OpenAIServiceError.emptyResponse
        }
        
        // Parse response to extract speech and theme
        let (speech, theme) = parseCallB_Response(content)

        // Use workingContext (which has the flag reset) as the base
        workingContext.coolUncleResponse = speech
        workingContext.responseTheme = theme

        // Hide transient status, add assistant bubble
        Task { @MainActor in
            uiStateService?.hideStatus()
            chatBubbleService?.addAssistantMessage(speech)
        }

        return workingContext
    }
    
    
    /// Get specialized system prompt for Call B (Cool Uncle speech)
    private func getCallB_SystemPrompt() -> String {
        return """
        You are Cool Uncle, a retro gaming expert with infectious enthusiasm for classic games.

        **CORE PERSONALITY**:
        - Enthusiastic but not overwhelming in length. (1-2 sentences max)
        - Focus on WHY games are great, not HOW to play them
        - Knowledgeable about gaming history and why these games changed gaming.
        - Never use emojis when speaking (responses are spoken aloud)
        - Sound like someone who has played every game and speakes with hype!
        - You're a video game lifer, you sleep, eat,and breathe video games.

        **UNIVERSAL SENTIMENT ACKNOWLEDGMENT** (ALWAYS APPLY FIRST):
        Check EVERY user message for sentiment before responding to commands/questions.
        - Sentiment detected → Brief acknowledgment (3-6 words) FIRST, then main response
        - Sentiment only (no command) → ONLY acknowledgment
        - Match intensity to their sentiment:
          * Strong positive ("I love this" / "This is amazing") → "I know, right?" / "It's so good!" / "Totally!"
          * Mild positive ("pretty fun" / "enjoying this") → "Glad you're digging it!" / "Nice!"
          * Strong negative ("I hate this" / "This sucks") → "Yeah, fair." / "Understood." / "I hear you."
          * Mild negative ("not feeling this") → "Fair enough." / "I get it."
        - If sentiment + command/question: Acknowledge first, then handle the command/question

        Examples:
        - User: "I love this game" → "I know, right? It's fantastic!"
        - User: "This is awesome! Can you recommend another platformer?" → "So glad you're loving it! Let me find you another great platformer..."
        - User: "This sucks, play something else" → "Yeah, fair. Let me find something better..."

        **SPEAKING STYLE**:
        - Vary your language like a human would - don't repeat the same phrases in your dialogue history.
        - Use connections: "Since you loved/played/want to play [X], you'll dig this because..." But vary your lines in how you make these connections.
        - Use the USER GAME PREFERENCES to understand that
          -🎮 Played Games = They launched the game, but it's unknown if the user liked or disliked the game
          -👎 Disliked Games = They verbally told you they hated the game or that it sucked.
          -⭐ Want to Play = They mentioned they want to play the game later, but likely didn't put a lot of time into it.
          - ❤️ Favorites = They said they loved this game.  You can actually reference these games the user loved.
        - Do not tell a user because they loved a game on Played, or Disliked list. 
        - Try to mirror the user's likes and dislikes, so you can diss games that are on the disliked list.

        **SMART REFERENCE PATTERNS**:
        Use category-appropriate language when making connections:
        - ❤️ Favorites → "Since you loved X..." "Your favorite X..." "Just like your beloved X..."
        - 🎮 Played → "Like X you recently played..." "Similar mechanics to X..." "If you enjoyed X..." "This has the same feel as X..."
        - ⭐ Want to Play → "Perfect timing since you wanted to try X..." "This scratches that X itch you mentioned..."
        - 👎 Disliked → "Unlike that boring X..." "This fixes everything wrong with X..."
        - Connect games by mechanics, genre, or style without assuming emotional attachment for Played games

        **CLEAN GAME TITLES**:
        Always remove these elements when speaking game names:
        - Region codes: (USA), (JP), (EU), (World)
        - Version numbers: (v1.0), (Rev A), (Beta)
        - Format indicators: [!], [a], [h], .nes, .sfc
        - Arcade codes: (JP49293), (set 1)
        - File extensions and paths

        Examples: "Street Fighter II (USA).sfc" → Say "Street Fighter two"

        **TASK-SPECIFIC BEHAVIOR**:
        You know what action was just taken and should respond accordingly.

        **CRITICAL FOR INFORMATIONAL QUESTIONS**:
        When action type is "informational" (informational question with no command):
        - FOCUS ON THE CURRENT USER MESSAGE ONLY
        - Answer their CURRENT question directly and concisely
        - Don't get confused by previous exchanges in conversation history
        - Be DIRECT - no excitement, no fluff, just the facts
        - One sentence answers are best for gameplay questions
        - Example: "To do a hadouken, quarter circle forward plus punch."

        **JSON RESPONSE FORMAT**:
        Your response should be a JSON object:
        {
            "speech": "Your enthusiastic response to the user",
        }

        **SPECIAL RULES**:
        - DO NOT REFERENCE an action when you Save a State or Load a State. DO NOT SPEAK when this command is given to you.

        **RESPONSE STYLE BASED ON CONTEXT**:
        Look at the action_type to understand what the user wanted, then respond naturally:

        - action_type: "launch_specific" = User asked for a specific game by name
          → Keep it brief but Hype - they know what they want!
          → The user knows this game well, so make a unique reference to the game's lore, key characters, or infamous moments.
          → Response should be 5 or 6 words tops.
          
        - action_type: "random" = User wanted a surprise
          → Tell them what you picked and why it's awesome
          → Connect to their gaming history when possible
          → Use their game preferences to explain why they'll enjoy it
          → NEVER ask "Want to play it?" - it's already launching!
          
        - action_type: "recommend" = You're suggesting something they'll love
          → Explain why this game fits them perfectly
          → Reference their favorites or recent games
          
        - action_type: "recommend_alternative" = They didn't like your last pick
          → Suggest something different with a fresh angle
          → "Let's try something different..." or "How about this instead..." "Allright...cool cool, how about ..."
          
        - action_type: "recommend_confirm" = Suggesting but they're mid-game
          → Be respectful of their current session
          → "When you're ready, [game] could be perfect because..."
          
        - action_type: "game_unavailable" = Couldn't find specific game, found alternative
          → Ask for confirmation before launching
          → "I couldn't find [requested game] but but I got [alternative]. Wanna play it?"
          
        - action_type: "no_games_on_system" = System has no games installed
          → Be humorous but helpful
          → Use one of the playful excuses then offer to refresh
          → "The nintendo ninjas locked down [system]... Or you might not have any games. Want me to refresh the game list?"
          
        - action_type: "game_not_found" = Specific game not in collection
          → Be understanding and clear
          → "I don't have [game] in your [system] collection"
          
        - action_type: "refresh_games" = User wants to index games
          → Be encouraging about the wait
          → "Alright, indexing your game collection. This might take a minute, so grab a snack!"
                
        - action_type: "stop" = Game ended
          → Check in casually: "How was that?" or "Want something similar?"

        **Example responses (be natural, vary your style)**:

        For RECCOMEND_CONFIRM responses:
        - "Oh man, you HAVE to try The Legend of Zelda! I love this game because it perfectly balances exploration with puzzle-solving... Want to play it?"
        - You need to get hype for the game you're reccomending, but end with a question about playing it.

        For INFORMATIONAL responses:
        - "Quarter circle forward plus punch."
        - "Hold back for two seconds, then forward plus punch."
        - "360 motion plus punch when close."
        - NO excitement, NO personal commentary, just the answer

        **CRITICAL: When action_type is "launch"**:
        The game is ALREADY launching - don't ask if they want to play it! Instead:
        - NEVER ask "Want to play it?" when a launch command was executed
        - NEVER give history lessons for games they specifically requested

        DO NOT:
        - Say "I hope you'll like it." or similar phrases when presenting a game, just give the reason and end your dialogue.
        - Mention technical details about commands or JSON
        - Be overly wordy or explanatory
        """
    }
    
    // MARK: - Action-Specific Call B Prompts
    
    /// Launch Specific: User requested a specific game by name
    private func buildCallB_LaunchSpecificPrompt(
        context: ThreeCallContext,
        executionResult: String,
        actualGameName: String?
    ) -> String {
        let gameName = actualGameName ?? "the game"
        
        // Extract system name from current game context
        let systemName = context.gameContextSnapshot.currentSystem ?? "MiSTer"
        
        return """
        **LAUNCH SPECIFIC RESPONSE GUIDELINES:**

        Response structure:
        - Remember to acknowledge the user's sentiment first if it exists in the user statement before saying your phrase
        - Let the sentiment acknowledgment flow naturally into your game-specific phrase
        - Generate a short game-specific phrase that shows you know the game's lore or memes and sounds like you're going or doing something

        Examples of good short game-specific phrases:
        - Wing Commander 2: "OK Commander Blair!"
        - Donkey Kong Country: "Let's smash barrels!"
        - Street Fighter II: "Time to Choose your fighter!"
        - Mega Man 2: "Lets get Equiped!"
        - Marvel Vs. Capcom 2: "I'm gonna take you for a ride!"
        - Chrono Trigger: "Don't get lost in time!"

        Use your knowledge of the game, or memes around the game to create a snappy short phrase that fans would recognize and appreciate.
        Be enthusiastic but concise. Show that you understand and love the content of the game they just launched.

        **YOUR TASK:**
        We launched \(gameName) on \(systemName).

        Generate your response following the guidelines above.
        """
    }
    
    /// Recommend: AI recommended this game to the user
    private func buildCallB_RecommendPrompt(
        context: ThreeCallContext,
        executionResult: String,
        actualGameName: String?,
        conversationContext: String,
        preferencesContext: String
    ) -> String {
        let gameName = actualGameName ?? "this game"
        return """
        **RECOMMENDATION RESPONSE GUIDELINES:**

        Explain why this is a great recommendation:
        - Give an enthusiastic but informative description of what makes this game special
        - Explain why it's perfect for them based on their preferences/history
        - Make smart connections using appropriate language:
          * For ❤️ Favorites: "Since you loved X..." or "Your favorite X..."
          * For 🎮 Played: "Like X you played..." or "Similar mechanics to X..."
          * Never say "loved" for games only in Played list
        - End with enthusiasm about the game, no confirmation questions needed

        Focus on WHY they should play it and get them excited about the recommendation!

        **YOUR TASK:**
        Recommended game: \(gameName)\(preferencesContext)

        Generate your recommendation response following the guidelines above.
        """
    }
    
    /// Random: AI selected a random game
    private func buildCallB_RandomPrompt(
        context: ThreeCallContext,
        executionResult: String,
        actualGameName: String?,
        conversationContext: String,
        preferencesContext: String
    ) -> String {
        let gameName = actualGameName ?? "this game"
        return """
        **RANDOM GAME RESPONSE GUIDELINES:**

        Response structure:
        - ONLY acknowledge user sentiment if they express emotion in their statement (excited, disappointed, nostalgic, etc.)
        - If NO sentiment is present, skip directly to game introduction
        - Tell the user why they might enjoy the game
        - Make smart connections using appropriate language:
          * For ❤️ Favorites: "Since you loved X..." or "Your favorite X..."
          * For 🎮 Played: "Like X you played..." or "Similar mechanics to X..."
          * Never say "loved" for games only in Played list
        - Be brief and enthusiastic!

        🚨 CRITICAL: \(gameName) is ALREADY RUNNING on the screen right now.
        You MUST describe \(gameName) - NEVER suggest a different game instead.
        Even if \(gameName) appears in 👎 Disliked Games, it's the game that launched.
        You can briefly acknowledge it ("Let's give it another shot!") but then describe what makes THIS game interesting.

        **EXAMPLES:**

        WITH sentiment:
        User: "Oh I love this game, how does this punch mechanic work?"
        Response: "Right?! It's amazing! For the punch mechanic..."

        WITHOUT sentiment (plain random request):
        User: "Play a random NES game"
        Response: "Low G Man has that unique gravity mechanic, similar to what you found in platforming action. Get ready for quirky adventures!"

        WITH excitement:
        User: "Surprise me with something awesome!"
        Response: "You got it! Mega Man 3 has incredible level design and some of the best music on the NES!"

        DISLIKED GAME (brief acknowledgment, then describe):
        User: "Play a random Sega game"
        [System randomly launches "Space Harrier" which is in 👎 Disliked Games]
        Response: "Let's give Space Harrier another shot! Those pseudo-3D scaling effects were groundbreaking. See if the fast-paced rail shooter action feels different this time!"

        **YOUR TASK:**
        You just launched \(gameName) at random.\(preferencesContext)

        Generate your response following the guidelines above.
        """
    }

    // buildCallB_VersionSwitchPrompt removed - now handled by VersionSwitchStrategy.buildCallBPrompt()

    /// Build context-aware prompt for Call B
    /// Returns tuple of (prompt, optional ModelConfig override)
    /// Override is used only for informational queries requiring higher accuracy
    private func buildCallB_SpeechPrompt(
        context: ThreeCallContext,
        executionResult: String
    ) async -> (prompt: String, config: ModelConfig?) {
        
        // Get last 25 conversation messages for richer context - EXCLUDE search results and system messages
        let filteredHistory = context.conversationHistory.suffix(25).filter { message in
            !message.content.contains("SYSTEM_INTERNAL_SEARCH_RESULTS") && 
            !message.content.contains("Search results found:") &&
            !message.content.contains("at path:")
        }
        let conversationContext = filteredHistory.isEmpty ? "" : 
            "\n\nConversation history:\n" + filteredHistory.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        
        // Include game preferences for personalized responses
        let preferencesContext = context.gamePreferences.isEmpty ? "" : "\n\nUser's game preferences:\n\(context.gamePreferences)"
        
        // For informational questions, emphasize the current question
        // Random games, launch_specific_exact, and recommend should NOT be treated as informational even if jsonCommand is nil
        let isInformational = (context.jsonCommand == nil || context.jsonCommand == "null") && context.actionType != "random" && context.actionType != "launch_specific_exact" && context.actionType != "recommend"
        
        if isInformational {
            // Check if this is about a pending recommendation
            if isPendingRecommendationValid(), let gameName = pendingRecommendationGameName {
                // User asking about the cached recommendation - build compelling sales narrative
                
                // Get conversation history to ensure variety - EXCLUDE search results and system messages
                let filteredHistory = context.conversationHistory.suffix(10).filter { message in
                    !message.content.contains("SYSTEM_INTERNAL_SEARCH_RESULTS") && 
                    !message.content.contains("Search results found:") &&
                    !message.content.contains("at path:")
                }
                let conversationContext = filteredHistory.isEmpty ? "" : 
                    "\n\nRecent conversation (vary your responses):\n" + filteredHistory.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                
                // Include full preferences for compelling narrative building
                let preferencesContext = context.gamePreferences.isEmpty ? "" : "\n\nPlayer profile:\n\(context.gamePreferences)"

                let prompt = """
                You're trying to convince the user to play \(gameName).

                Their question: "\(context.userMessage)"

                Answer their specific question about \(gameName) while selling the game.

                Build your pitch using:
                - If they've WANTED TO PLAY it: "You mentioned wanting to try this!"
                - Compare to FAVORITES: "Since you loved [game], you'll enjoy this because..."
                - Contrast with DISLIKED: "Unlike [hated game], this one actually..."
                - Reference their play history for connections

                CRITICAL RULES:
                - Answer their question accurately first
                - Keep response to 2-3 sentences max
                - End with varied invitation: "Want to play it?" / "Should I launch it?" / "Ready to try it?" / "Want me to fire it up?"
                - NEVER repeat previous responses - check conversation history
                - Sound like a human friend, not a salesperson
                - Be specific about game features when answering\(preferencesContext)\(conversationContext)
                """

                // OVERRIDE: Informational questions need gpt-4o for accuracy
                return (prompt, .callBInformational())
            } else {
                // Regular informational question about current game
                // For informational questions, EXCLUDE search results and system messages from history
                let filteredHistory = context.conversationHistory.suffix(4).filter { message in
                    !message.content.contains("SYSTEM_INTERNAL_SEARCH_RESULTS") && 
                    !message.content.contains("Search results found:") &&
                    !message.content.contains("at path:")
                }
                let limitedContext = filteredHistory.isEmpty ? "" : 
                    "\n\nRecent context (for game reference only):\n" + filteredHistory.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                
                // Get current game context for "this game" references using snapshot
                let gameReference: String
                let snapshot = context.gameContextSnapshot
                if let currentGame = snapshot.currentGame, let currentSystem = snapshot.currentSystem {
                    gameReference = "\n\nCurrently running game: \(currentGame) on \(currentSystem)"
                } else if let currentGame = snapshot.currentGame {
                    gameReference = "\n\nCurrently running game: \(currentGame)"
                } else {
                    gameReference = ""
                }

                let prompt = """
                **RESPONSE FRAMEWORK - Process in this order:**

                STEP 1: CHECK FOR SENTIMENT (always check first)
                - Does the user express emotion with explicit emotional words? (love/hate/excited/frustrated/enjoying/boring/awesome/sucks/amazing/terrible/fun)
                - PURE INFORMATION QUESTIONS ARE NOT SENTIMENT:
                  * "Is there a difference between..." → NO sentiment
                  * "How does X work?" → NO sentiment
                  * "What is..." / "Why does..." / "When should..." → NO sentiment
                  * "Can I..." / "Should I..." → NO sentiment
                - If YES (explicit emotion present): You MUST acknowledge their feeling first, then proceed to step 2
                - If NO (pure information question): Skip directly to step 2

                STEP 2: CHECK FOR QUESTION
                - Is the user asking for information?
                - If YES: Answer their question (see guidelines below)
                - If NO: You're done (sentiment acknowledgment is the complete response)

                STEP 3: CHECK FOR PLAYLIST/MARKING REQUEST
                - Is the user asking to add game to playlist/list/favorites/dislikes?
                - If YES: Respond enthusiastically confirming it's done
                  * "Add to playlist/list" → "Done! I've added [game] to your Want to Play list."
                  * "Mark as favorite/I love this" → "Got it! Added [game] to your favorites."
                  * "I don't like this/Mark as disliked" → "Noted! Added [game] to your disliked list."
                - Keep it brief and enthusiastic - the system handles this automatically

                **SENTIMENT ACKNOWLEDGMENT (when detected):**
                - Match their emotional intensity and share their feeling:
                  * Strong positive ("I love this" / "This is amazing") → "I know, right? The [specific feature] is so good!"
                  * Mild positive ("enjoying this" / "pretty fun") → "Yeah! It's really well done."
                  * Strong negative ("I hate this" / "This sucks") → "Yeah, I feel you." / "Fair."
                  * Mild negative ("not feeling this") → "I hear you."
                - Make it feel like you're in it WITH them, not observing from outside

                **GAME NAME REDUNDANCY RULE:**
                - DO NOT preface your answer with "In [game name]..." or "[game name] has..."
                - The player already knows what game they're playing (it was announced at launch)
                - Answer directly without restating the game name
                - Exception: When comparing to other games, references like "Unlike the arcade version..." or "The SNES version..." are fine
                - Focus on the factual answer, not context the user already has

                **ANSWERING QUESTIONS (when present):**

                Mirror their depth and verbosity:

                1. SHORT/DIRECT QUESTIONS (minimal context):
                   - "How do I save?" → "Alt+F1"
                   - "What button jumps?" → "A button"
                   - One sentence max, just the answer

                2. CONTEXTUAL/NUANCED QUESTIONS (they provide background):
                   - "I'm stuck on the water temple, tried everything" → Match their depth, provide thoughtful guidance
                   - "The combat feels different than the first game" → Engage with their observation, explain the differences
                   - Provide 2-3 sentences with context that addresses their specific situation

                3. SENTIMENT + QUESTION (acknowledge first, then answer):
                   - "I love this game, how do I save?" → "Glad you're loving it! Alt+F1 to save."
                   - "This is confusing, how does magic work?" → "It's a bit tricky at first. You charge with the B button, then release to cast."

                **EXAMPLES:**
                - "I love this game" → "I know, right? The combat is so satisfying!" (sentiment + no question)
                - "This is boring" → "Yeah, fair." (sentiment + no question)
                - "How do I save?" → "Alt+F1" (NO sentiment, just answer - no game name needed)
                - "Is there a difference between the two characters?" → "Both characters have the same stats and controls, but different special moves." (NO sentiment, just answer - no game name needed)
                - "I love this game, how do I save?" → "Glad you're loving it! Alt+F1 to save." (sentiment + question)
                - "This is confusing, how does magic work?" → "It's a bit tricky at first. You charge with the B button, then release to cast." (sentiment + question)
                - "I'm really enjoying the story but I'm stuck on the locked door in the lab" → "The story is great, right? For that door, you need the blue keycard from the security office on level 2." (sentiment + question)
                - "The controls feel really tight compared to the first game" → "Yeah, they really refined them! The movement is way more responsive, and the jump physics are more precise." (sentiment + question)

                **CRITICAL CONTEXT RULES:**
                - If user says "this game", they mean the currently running game
                - Focus on answering the CURRENT question, not previous ones
                - Use context to understand WHAT they're asking about (which game, which level, which boss)
                - Match the user's communication style: brief = brief, detailed = detailed
                - When user says ambiguous things ("yes", "that one", "the next level"), use recent context to clarify
                - Context helps you understand the CURRENT request, never answer an OLD request instead

                **━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━**
                **🎯 CURRENT REQUEST (PRIMARY FOCUS):**
                User said: "\(context.userMessage)"\(gameReference)
                **━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━**

                **CONTEXT USAGE RULES:**
                ✅ Use recent context ONLY when:
                   - Current request contains ambiguous references ("that one", "yes", "level 2" after discussing bosses)
                   - User pronouns need clarification ("it", "that game", "this one")
                   - Enriching a clear request with relevant past preferences

                ❌ NEVER use context to:
                   - Substitute an old request for the current one
                   - Answer a previous question instead of the current one
                   - Ignore what the user just said

                Recent conversation context (use for clarification/enrichment only):\(limitedContext)

                Generate Cool Uncle's response following the framework above.
                """

                // OVERRIDE: Informational questions need gpt-4o for accuracy
                return (prompt, .callBInformational())
            }
        } else {
            // Special handling for no games on system
            if context.actionType == "no_games_on_system" {
                let systemName = extractSystemFromUserMessage(context.userMessage) ?? "that system"
                let prompt = """
                System check result: No games found on \(systemName)

                Generate a humorous but helpful response:
                1. Use one of these playful excuses (or similar):
                   - "The nintendo ninjas have locked down \(systemName)"
                   - "The \(systemName) overlords are blocking me"
                   - "\(systemName) decided to take a day off"
                   - "My \(systemName) decoder ring is missing"
                2. Then add: "...Or you might not have any \(systemName) games on your MiSTer yet."
                3. End with: "Want me to refresh the game list? This can take a minute..."

                Keep it light and helpful!
                """
                return (prompt, nil)
            }

            // Special handling for game indexing
            if context.actionType == "refresh_games" {
                let prompt = """
                User requested to refresh/index games.

                Generate an encouraging response about the wait:
                - "Alright, indexing your game collection. This might take a minute, so grab a snack!"
                - "Starting the game scan. Perfect time for a quick stretch!"
                - "Refreshing your game library. This could take a bit, but it'll be worth it!"

                Keep it upbeat and set expectations about the wait.
                """
                return (prompt, nil)
            }
            
            // Extract actual game name for action-specific prompts
            let actualGameName: String?
            if executionResult.contains(" - Actual game: ") {
                let parts = executionResult.components(separatedBy: " - Actual game: ")
                actualGameName = parts.count > 1 ? parts[1] : await MainActor.run { CurrentGameService.shared.currentGameName }
            } else {
                actualGameName = await MainActor.run { CurrentGameService.shared.currentGameName }
            }
            
            // Route to action-specific prompt builders
            switch context.actionType {
            case "launch_specific", "launch_specific_exact":
                let prompt = buildCallB_LaunchSpecificPrompt(
                    context: context,
                    executionResult: executionResult,
                    actualGameName: actualGameName
                )
                return (prompt, nil)

            case "recommend", "recommend_alternative":
                let prompt = buildCallB_RecommendPrompt(
                    context: context,
                    executionResult: executionResult,
                    actualGameName: actualGameName,
                    conversationContext: conversationContext,
                    preferencesContext: preferencesContext
                )
                return (prompt, nil)
                
            case "recommend_confirm":
                // For recommend_confirm, we've cached the command and need to ask for confirmation
                let gameName = pendingRecommendationGameName ?? "a game"

                let prompt: String
                if context.needsSalesPitch {
                    // User asked about the game - sell it with enthusiasm!
                    prompt = """
                    You MUST mention "\(gameName)" by name when answering.

                    User asked about \(gameName) that you recommended.
                    SELL this specific game based on their preferences! Be enthusiastic about:
                    - Why it's perfect for them specifically
                    - What makes it special and exciting
                    - How it connects to games they love
                    - Key features they'd enjoy

                    End with a soft close like:
                    - "Want to give it a try?"
                    - "Should I fire it up?"
                    - "Ready to dive in?"
                    - "Worth launching?"

                    Keep them engaged and excited! Make them WANT to play it.\(conversationContext)\(preferencesContext)
                    """
                } else {
                    // Normal recommend_confirm flow - respectful suggestion
                    prompt = """
                    You MUST mention "\(gameName)" by name in your response.

                    Ask the user if they want to launch \(gameName).
                    Be natural and vary your phrasing, but always include the game name.
                    End with a confirmation question.\(conversationContext)\(preferencesContext)
                    """
                }
                return (prompt, nil)

            case "random":
                let prompt = buildCallB_RandomPrompt(
                    context: context,
                    executionResult: executionResult,
                    actualGameName: actualGameName,
                    conversationContext: conversationContext,
                    preferencesContext: preferencesContext
                )
                return (prompt, nil)

            case "version_switch":
                // Build prompt with AI's selection reasoning if available from deferred response
                let currentGame = context.gameContextSnapshot.currentGame ?? "that game"
                let switchedGame = actualGameName ?? "a different version"

                let reasonSection: String
                if let reason = pendingSelectionReason {
                    reasonSection = """

                    **WHY THIS VERSION WAS SELECTED:**
                    \(reason)

                    Use this reasoning to explain to the user why you picked this version. Make it conversational and cool sounding!
                    """
                    // Clear after use to prevent stale data in future calls
                    pendingSelectionReason = nil
                } else {
                    reasonSection = """

                    Respond with enthusiasm about the version switch (2-3 sentences):
                    - If they asked for specific platform (NES, arcade, etc) → mention something nostalgic about the user chosen platform
                    - If they asked for language/region → confirm the switch in a casual way.
                    - If they asked for "better" → briefly explain what makes this version better
                    """
                }

                let prompt = """
                You just switched from a different version to: \(switchedGame).
                \(reasonSection)

                Examples of good responses:
                - "Yeah! the Arcade verision has the best graphics and sound!"
                - "English Version. Got it!"
                - "You like to kick it oldschool too? I got you."
                - "Yep, The Japanese verison has all the cut content from the US Version."
                - "Yeah, I like this version better anyway."
                - "This is my favorite version."

                Previous game: \(currentGame)
                User requested: "\(context.userMessage)"
                """
                return (prompt, nil)

            case "confirm_yes":
                let prompt = buildCallB_ConfirmYesPrompt(
                    context: context,
                    executionResult: executionResult
                )
                return (prompt, nil)

            case "confirm_no":
                let prompt = buildCallB_ConfirmNoPrompt(
                    context: context,
                    conversationContext: conversationContext
                )
                return (prompt, nil)

            case "confirm_info":
                let prompt = buildCallB_ConfirmInfoPrompt(
                    context: context,
                    conversationContext: conversationContext,
                    preferencesContext: preferencesContext
                )
                return (prompt, nil)

            default:
                // Fallback for other action types (utility commands, etc.)
                let gameInfo = actualGameName != nil ? "\nActual game launched: \(actualGameName!)" : ""
                let prompt = """
                User said: "\(context.userMessage)"

                Action taken: \(context.actionType ?? "unknown")
                Action context: \(context.actionContext ?? "none")
                Execution result: \(executionResult)\(gameInfo)\(conversationContext)\(preferencesContext)

                Respond naturally based on the action taken.
                """
                return (prompt, nil)
            }
        }
    }
    
    /// Parse Call B response to extract speech and theme
    private func parseCallB_Response(_ content: String) -> (speech: String, theme: String?) {
        // Strip markdown code fences if present (gpt-4o sometimes wraps JSON in ```json...```)
        var cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove opening code fence (```json or ```)
        if cleanedContent.hasPrefix("```json") {
            cleanedContent = String(cleanedContent.dropFirst(7)) // Remove "```json\n"
        } else if cleanedContent.hasPrefix("```") {
            cleanedContent = String(cleanedContent.dropFirst(3)) // Remove "```\n"
        }

        // Remove closing code fence (```)
        if cleanedContent.hasSuffix("```") {
            cleanedContent = String(cleanedContent.dropLast(3))
        }

        cleanedContent = cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse as JSON
        if let data = cleanedContent.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let speech = json["speech"] as? String {
            let theme = json["theme"] as? String
            return (speech: speech.trimmingCharacters(in: .whitespacesAndNewlines), theme: theme)
        }

        // Fallback: treat entire cleaned content as speech
        return (speech: cleanedContent, theme: nil)
    }

    /// Set a canned response and update UI (Consumer UI integration)
    /// Centralizes UI updates for all canned/error responses to prevent stuck "Generating response..." messages
    /// - Parameter speech: The canned response text to display
    private func setCannedResponse(_ speech: String) {
        coolUncleResponse = speech

        // Hide transient status, add assistant bubble (Consumer UI integration)
        Task { @MainActor in
            uiStateService?.hideStatus()
            chatBubbleService?.addAssistantMessage(speech)
        }
    }

    // MARK: - Call C (Sentiment Analysis) - REMOVED
    // Call C has been extracted to SentimentAnalysisService.swift for better code organization
    // See SentimentAnalysisService.swift for all sentiment analysis logic

    /// Confirm Yes: User confirmed the recommendation
    private func buildCallB_ConfirmYesPrompt(
        context: ThreeCallContext,
        executionResult: String
    ) -> String {
        return """
        User confirmed the recommendation. The game is now launching.

        Response: Brief confirmation like "Great! Launching now..." or "Here we go!"
        Keep it short - the game is already starting.
        """
    }

    /// Confirm No: User rejected the recommendation
    private func buildCallB_ConfirmNoPrompt(
        context: ThreeCallContext,
        conversationContext: String
    ) -> String {
        return """
        User rejected the recommendation.\(conversationContext)

        Response: Understanding and offer alternatives like "No problem! What kind of game would you prefer?"
        or "Alright, want something with more action?"
        """
    }

    /// Confirm Info: User wants information about the pending recommendation
    private func buildCallB_ConfirmInfoPrompt(
        context: ThreeCallContext,
        conversationContext: String,
        preferencesContext: String
    ) -> String {
        let gameName = pendingRecommendationGameName ?? "the recommended game"
        return """
        User wants information about \(gameName).\(conversationContext)\(preferencesContext)

        Response: Provide engaging details about gameplay, why it's fun, what makes it special.
        End with "Want to give it a try?" to prompt confirmation.
        """
    }

    // MARK: - Network Layer

    /// Make HTTP request to OpenAI API (routes to proxy or direct based on configuration)
    internal func makeOpenAIRequest(
        callPhase: String,
        context: String,
        requestBody: [String: Any],
        apiKey: String
    ) async throws -> [String: Any] {
        if useCloudflareProxy {
            return try await makeCloudflareProxyRequest(
                callPhase: callPhase,
                context: context,
                requestBody: requestBody
            )
        } else {
            return try await makeDirectOpenAIRequest(
                callPhase: callPhase,
                context: context,
                requestBody: requestBody,
                apiKey: apiKey
            )
        }
    }

    /// Make HTTP request via Cloudflare proxy
    private func makeCloudflareProxyRequest(
        callPhase: String,
        context: String,
        requestBody: [String: Any]
    ) async throws -> [String: Any] {
        // DEBUG: Simulate network timeout for testing retry mechanism
        #if DEBUG
        if simulateNetworkTimeout {
            AppLogger.openAI("🧪 DEBUG: Simulating network timeout (simulateNetworkTimeout=true)")
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "The request timed out (simulated for testing)."]
            )
        }
        #endif

        guard let url = URL(string: cloudflareProxyURL) else {
            throw OpenAIServiceError.invalidURL
        }

        // Track timing for analytics (client-side only for latency measurement)
        let startTime = Date()

        // Log the request using three-tier logging
        let messages = requestBody["messages"] as? [[String: Any]] ?? []
        let lastMessage = messages.last?["content"] as? String ?? ""

        // Log complete request for SearchTerms calls to debug prompt issues
        if callPhase == "A-SearchTerms" {
            let fullRequest = messages.map { message in
                let role = message["role"] as? String ?? "unknown"
                let content = message["content"] as? String ?? ""
                return "\(role.uppercased()):\n\(content)"
            }.joined(separator: "\n\n")

            #if DEBUG
            print("🔧 === COMPLETE SEARCH TERMS REQUEST ===")
            print(fullRequest)
            print("🔧 ======================================")
            #endif
        }

        AppLogger.aiRequestWithTruncation(
            phase: callPhase,
            context: context,
            fullPrompt: lastMessage,
            truncateLength: 50
        )

        // Add metadata to request body for Cloudflare analytics
        var proxyRequestBody = requestBody
        proxyRequestBody["user_id"] = CloudflareService.shared.getUserID()
        proxyRequestBody["call_type"] = normalizeCallPhase(callPhase)
        proxyRequestBody["action_type"] = context

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        // No Authorization header - proxy handles OpenAI API key
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: proxyRequestBody)
        } catch {
            throw OpenAIServiceError.invalidRequest("Failed to encode request body")
        }

        // Retry logic for network timeouts
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIServiceError.networkError("Invalid response")
                }

                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    // No need to log analytics - proxy logs errors server-side
                    throw OpenAIServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
                }

                // Success! Parse and return
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw OpenAIServiceError.parseError("Invalid JSON response")
                }

                // Log the response based on phase
                logResponseForPhase(callPhase, json, requestBody)

                // No need to log analytics to Cloudflare - proxy already logged it server-side

                return json
            } catch {
                lastError = error
                let nsError = error as NSError

                // Only retry on timeout errors
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut && attempt < maxRetries {
                    AppLogger.openAI("⚠️ Request timed out (attempt \(attempt + 1)/\(maxRetries + 1)), retrying...")
                    continue
                }

                // For non-timeout errors or final attempt, throw immediately
                throw error
            }
        }

        // Should never reach here, but satisfy compiler
        throw lastError ?? OpenAIServiceError.networkError("Request failed after retries")
    }

    /// Make HTTP request directly to OpenAI API (dormant fallback for BYOK)
    private func makeDirectOpenAIRequest(
        callPhase: String,
        context: String,
        requestBody: [String: Any],
        apiKey: String
    ) async throws -> [String: Any] {
        // DEBUG: Simulate network timeout for testing retry mechanism
        #if DEBUG
        if simulateNetworkTimeout {
            AppLogger.openAI("🧪 DEBUG: Simulating network timeout (simulateNetworkTimeout=true)")
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "The request timed out (simulated for testing)."]
            )
        }
        #endif

        guard let url = URL(string: baseURL) else {
            throw OpenAIServiceError.invalidURL
        }

        // Track timing for analytics
        let startTime = Date()

        // Log the request using three-tier logging
        let messages = requestBody["messages"] as? [[String: Any]] ?? []
        let lastMessage = messages.last?["content"] as? String ?? ""

        // Log complete request for SearchTerms calls to debug prompt issues
        if callPhase == "A-SearchTerms" {
            let fullRequest = messages.map { message in
                let role = message["role"] as? String ?? "unknown"
                let content = message["content"] as? String ?? ""
                return "\(role.uppercased()):\n\(content)"
            }.joined(separator: "\n\n")

            #if DEBUG
            print("🔧 === COMPLETE SEARCH TERMS REQUEST ===")
            print(fullRequest)
            print("🔧 ======================================")
            #endif
        }

        AppLogger.aiRequestWithTruncation(
            phase: callPhase,
            context: context,
            fullPrompt: lastMessage,
            truncateLength: 50
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw OpenAIServiceError.invalidRequest("Failed to encode request body")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"

            throw OpenAIServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIServiceError.parseError("Invalid JSON response")
        }

        // Log the response based on phase
        logResponseForPhase(callPhase, json, requestBody)

        return json
    }

    /// Normalize call phase to standard format (call_a, call_b, call_c)
    private func normalizeCallPhase(_ phase: String) -> String {
        if phase.hasPrefix("A-") || phase.contains("Call A") {
            return "call_a"
        } else if phase.hasPrefix("B-") || phase.contains("Call B") {
            return "call_b"
        } else if phase.hasPrefix("C-") || phase.contains("Call C") {
            return "call_c"
        }
        return phase.lowercased().replacingOccurrences(of: " ", with: "_")
    }
    
    /// Extract content from OpenAI API response
    private func extractContentFromResponse(_ response: [String: Any]) -> String? {
        guard let choices = response["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }
    
    /// Log responses based on explicit phase with appropriate formatting
    private func logResponseForPhase(
        _ phase: String,
        _ responseJson: [String: Any],
        _ requestBody: [String: Any]
    ) {
        // Extract token usage if available
        let usage = responseJson["usage"] as? [String: Any]
        let totalTokens = usage?["total_tokens"] as? Int ?? 0
        
        // Extract the actual response content
        guard let content = extractContentFromResponse(responseJson) else {
            AppLogger.standard("❌ Call \(phase): Empty response")
            return
        }

        // Log based on phase with appropriate formatting
        switch phase {
        case "A":
            // Show raw JSON response (no parsing - makes it easy to spot LLM hallucinations)
            AppLogger.aiResponseWithDetail(
                phase: "A",
                response: "✅ Call A Response: \(content)"
            )

        case "B":
            // Call B responses are logged naturally in ContentView as clean speech text
            // Raw AI response is already logged above for debugging
            // No additional processing needed here to avoid duplication
            break
            
        case "C":
            // Extract sentiment result
            if content.contains("negative") {
                AppLogger.aiResponseWithDetail(
                    phase: "C",
                    response: "✅ Sentiment: negative → Will add to Disliked"
                )
            } else if content.contains("positive") {
                AppLogger.aiResponseWithDetail(
                    phase: "C",
                    response: "✅ Sentiment: positive → Will add to Favorites"
                )
            } else if content.contains("neutral") {
                AppLogger.aiResponseWithDetail(
                    phase: "C",
                    response: "✅ Sentiment: neutral → No preference update"
                )
            } else {
                AppLogger.aiResponseWithDetail(
                    phase: "C",
                    response: "✅ Sentiment analysis completed"
                )
            }
            
        case "A-GameSelection":
            // Show raw JSON response for debugging
            AppLogger.openAI("✅ Call A-GameSelection Response: \(content)")
            
        default:
            AppLogger.standard("✅ Call \(phase) Response received")
        }
        
        // Token warning only when high
        AppLogger.tokenWarning(totalTokens, phase: phase)
        
        // Verbose mode: Full prompt/response to file
        if AppLogger.isVerbose {
            let model = requestBody["model"] as? String ?? "unknown"
            
            // Get the full prompt from the request
            let messages = requestBody["messages"] as? [[String: Any]] ?? []
            let fullPrompt = messages.last?["content"] as? String ?? ""
            
            AppLogger.openAI("""
            === Call \(phase) Full Exchange ===
            Model: \(model)
            Tokens: \(totalTokens)
            
            REQUEST:
            \(fullPrompt)
            
            RESPONSE:
            \(content)
            =====================================
            """)
        }
    }
    
    // MARK: - JSON Validation
    
    /// Validate generated JSON command
    private func validateJSONCommand(_ jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8) else {
            throw OpenAIServiceError.parseError("Invalid JSON string encoding")
        }
        
        // Parse JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIServiceError.parseError("Invalid JSON format")
        }
        
        // Validate JSON-RPC 2.0 structure
        guard let jsonrpc = json["jsonrpc"] as? String, jsonrpc == "2.0" else {
            throw OpenAIServiceError.parseError("Missing or invalid jsonrpc field")
        }
        
        guard json["id"] != nil else {
            throw OpenAIServiceError.parseError("Missing id field")
        }
        
        guard let method = json["method"] as? String, !method.isEmpty else {
            throw OpenAIServiceError.parseError("Missing or empty method field")
        }
        
        // Validate known methods
        let validMethods = ["media.search", "launch", "stop", "systems"]
        guard validMethods.contains(method) else {
            throw OpenAIServiceError.parseError("Unknown method: \(method)")
        }
    }
    
    // MARK: - Legacy Zero Search Results Handling (Removed)
    
    // Legacy retry system removed - optimized search handles all game matching
    // Zero results now handled directly in optimized search strategies
    
    // MARK: - Deferred Response Handling
    
    /// Update the pending context with correct actionType when better info is available
    func updatePendingContextActionType(_ actionType: String) {
        guard var context = pendingContext else { return }
        if context.actionType != actionType {
            #if DEBUG
            print("🔧 UPDATING pending context actionType: '\(context.actionType ?? "nil")' → '\(actionType)'")
            #endif
            context.actionType = actionType
            pendingContext = context
        }
    }
    
    /// Complete the deferred Call B response after game launch
    func completeDeferredResponse(actualGameName: String) async {
        guard let context = pendingContext,
              let _ = pendingExecutionResult,
              let apiKey = pendingApiKey else {
            AppLogger.openAI("⏭️ No pending response to complete")
            return
        }

        // Notify Call C dispatch service of A/B activity
        CallCDispatchService.shared.notifyABActivity()

        AppLogger.verbose("🎯 Completing deferred Call B response for: \(actualGameName)")
        AppLogger.emit(type: .debug, content: "⏱️ TIMING: DEFERRED_CALL_B_TRIGGERED at \(Date().timeIntervalSince1970) for game: \(actualGameName)")

        // Create fresh execution result with actual game name (ignore potentially stale pendingExecutionResult)
        let updatedResult = "Command executed successfully - Actual game: \(actualGameName)"

        // UPDATE: Create fresh context with updated game state from CurrentGameService
        // This prevents stale system context from when the user originally spoke
        // Use pendingContext which has the correct actionType set by updatePendingContextActionType()
        var updatedContext = pendingContext ?? context
        updatedContext.gameContextSnapshot = CurrentGameService.shared.createGameContextSnapshot(
            forUserMessage: context.userMessage
        )

        do {
            // Check if we have a strategy and decision from optimized search (e.g., version_switch)
            if let strategy = pendingStrategy, let decision = pendingDecision {
                AppLogger.openAI("🎯 Using strategy-specific Call B prompt for: \(context.actionType ?? "unknown")")

                // Use strategy's specialized Call B prompt
                let callBPrompt = strategy.buildCallBPrompt(decision: decision, context: updatedContext)
                let response = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)

                updatedContext.coolUncleResponse = response

                // Update published properties
                AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(response)' via EnhancedOpenAIService:DEFERRED_CALL_B_SUCCESS_STRATEGY")
                coolUncleResponse = response
                threeCallContext = updatedContext
            } else {
                // Fall back to generic Call B generation for non-optimized paths
                AppLogger.verbose("🎯 Using generic Call B generation (no strategy)")

                let finalContext = try await executeCallB_SpeechGeneration(
                    context: updatedContext,  // Use updated context with fresh game state
                    executionResult: updatedResult,
                    apiKey: apiKey
                )

                // Update published properties
                let newResponse = finalContext.coolUncleResponse ?? ""
                AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(newResponse)' via EnhancedOpenAIService:DEFERRED_CALL_B_SUCCESS_GENERIC")
                coolUncleResponse = newResponse
                threeCallContext = finalContext
            }

        } catch {
            AppLogger.openAI("❌ Deferred Call B failed: \(error)")
            // Fallback response
            let fallbackResponse = "I'm sorry, but something's gone wrong with that launch."
            AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(fallbackResponse)' via EnhancedOpenAIService:DEFERRED_CALL_B_FAILURE")
            coolUncleResponse = fallbackResponse
        }

        // Clear pending state
        clearPendingResponse()
    }
    
    /// Provide fallback response if game doesn't launch within timeout
    func provideFallbackResponse() {
        guard pendingContext != nil else { return }
        
        AppLogger.openAI("⏰ Timeout reached - providing fallback response")
        let fallbackResponse = "I'm sorry, but something's gone wrong with that launch."
        AppLogger.emit(type: .debug, content: "🔧 RESPONSE SET: '\(fallbackResponse)' via EnhancedOpenAIService:3314 FALLBACK_TIMEOUT")
        coolUncleResponse = fallbackResponse
        clearPendingResponse()
    }
    
    /// Clear pending response state
    private func clearPendingResponse() {
        pendingContext = nil
        pendingExecutionResult = nil
        pendingApiKey = nil
        pendingSelectionReason = nil
        pendingStrategy = nil
        pendingDecision = nil
    }
    
    // MARK: - Optimized Search Infrastructure
    
    /// CALL GameSelection: Pick the best ROM from search results using fuzzy matching and quality criteria
    /// Temperature: 0.3, analysis-focused, JSON response format for structured selection
    private func executeCallGameSelection(
        availableGames: [String: String],
        targetGame: String,
        userMessage: String,
        actionType: String = "launch_specific",
        currentSystem: String? = nil,
        mustPick: Bool = false,
        apiKey: String
    ) async throws -> (selectedGame: String?, selectedPath: String?, failureReason: String?) {

        let prompt = await buildGameSelectionPrompt(
            games: availableGames,
            target: targetGame,
            userMessage: userMessage,
            actionType: actionType,
            currentSystem: currentSystem,
            mustPick: mustPick
        )

        let requestBody: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0.3,
            "max_tokens": 300,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "You are a game selection AI that picks the best ROM from search results based on fuzzy matching and quality criteria. Always respond with valid JSON."],
                ["role": "user", "content": prompt]
            ]
        ]

        // CRITICAL: Follow ABC pattern with explicit phase
        let response = try await makeOpenAIRequest(
            callPhase: "A-GameSelection",  // Phase 2 game selection
            context: "executeCallGameSelection",
            requestBody: requestBody,
            apiKey: apiKey
        )

        // Parse the JSON response
        guard let content = extractContentFromResponse(response),
              let data = content.data(using: .utf8),
              let selectionResult = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIServiceError.parseError("Failed to parse game selection JSON response")
        }

        // Check if a match was found
        if let found = selectionResult["found"] as? Bool, found,
           let bestMatch = selectionResult["best_match"] as? String,
           let path = selectionResult["path"] as? String {
            // Extract success reason (e.g., "Arcade version has better sound and graphics")
            let reason = selectionResult["reason"] as? String
            return (bestMatch, path, reason)
        } else {
            // Extract failure reason if available
            let reason = selectionResult["reason"] as? String ?? "No suitable match found"
            return (nil, nil, reason)
        }
    }
    
    /// Build game selection prompt with ROM quality criteria
    /// OPTIMIZED FOR CACHING: Static content first, dynamic content last (75% cache hit rate)
    private func buildGameSelectionPrompt(
        games: [String: String],
        target: String,
        userMessage: String,
        actionType: String = "launch_specific",
        currentSystem: String? = nil,
        mustPick: Bool = false
    ) async -> String {

        // VERSION SWITCH uses specialized prompt (same game, different platform)
        if actionType == "version_switch" {
            return await buildVersionSwitchSelectionPrompt(
                games: games,
                target: target,
                userMessage: userMessage,
                currentSystem: currentSystem ?? "unknown",
                mustPick: mustPick
            )
        }

        // FORMAT GAMES LIST (for non-version_switch actions)
        let sortedGames = games.sorted { $0.key < $1.key }
        var formattedResults = ""

        for (index, (name, path)) in sortedGames.enumerated() {
            formattedResults += "\(index + 1). \"\(name)\" at path: \(path)\n"
        }

        // Add avoid list and preferences context for recommendations
        let avoidListSection: String
        let preferencesSection: String
        if actionType.contains("recommend") {
            // Get avoid days setting (default to 7 if not set)
            let avoidDays = await MainActor.run {
                let days = UserDefaults.standard.integer(forKey: "avoidGamesDays")
                return days == 0 ? 7 : days
            }
            let recentGames = await MainActor.run { UserGameHistoryService.shared.getRecentlyPlayedGames(days: avoidDays) }

            if !recentGames.isEmpty {
                avoidListSection = """

                **AVOID LIST - RECENTLY PLAYED GAMES:**
                \(recentGames.map { "- \($0)" }.joined(separator: "\n"))
                """
            } else {
                avoidListSection = ""
            }

            // Get favorites and dislikes from preferences
            let preferences = await MainActor.run { GamePreferenceService.shared.getPreferenceContextForAI() }
            preferencesSection = """

            \(preferences)
            """
        } else {
            // Include preferences for direct launches to inform version selection
            let preferences = await MainActor.run { GamePreferenceService.shared.getPreferenceContextForAI() }
            preferencesSection = preferences.isEmpty ? "" : """

            USER'S GAME PREFERENCES (for version selection):
            \(preferences)
            """
            avoidListSection = ""
        }

        // Adjust task description based on type
        let taskDescription = actionType.contains("recommend") ?
            "TASK: Pick the BEST game for a RECOMMENDATION using fuzzy matching, ROM quality, and avoid list criteria." :
            "TASK: Pick the BEST matching game using fuzzy matching and ROM selection criteria."

        // CACHING OPTIMIZATION: Static rules first (conditional on actionType), dynamic content last
        // Exact launches and recommendations get different static rule sets for clear separation
        let staticRules: String
        if actionType.contains("recommend") {
            staticRules = """
            FUZZY MATCHING RULES:
            - Ignore punctuation differences (: vs , vs -)
            - Ignore word order ("The Legend" vs "Legend, The")
            - Handle abbreviations (Bros = Brothers, 3 = III, 2 = II)
            - Regional awareness: "Streets of Rage" = USA preference, "Bare Knuckle" = Japanese

            CRITICAL SELECTION RULES:
            1. ITERATE through ALL games systematically to find ones NOT on avoid list
            2. VARIETY PRIORITY: User wants "different type" - pick unfamiliar games over favorites
            3. WHEN IN DOUBT: Pick something you don't recognize to give user new experiences
            4. FUZZY AVOID MATCHING: If a game's base title matches an avoided game, treat it as avoided too
               - Example: If "Legend of Zelda, The - A Link to the Past (USA)" is avoided, also avoid regional variants
               - Strip region/language indicators: (USA), (Europe), (Japan), (Canada), (France), (Germany), (En), (Fr), (De), etc.
               - Compare base game titles after stripping regional tags
            5. ALWAYS find a game - with diverse search results, alternatives always exist

            BEFORE SELECTING: Double-check your chosen game is NOT in the avoid list AND not a regional variant

            RETURN FORMAT (JSON only):
            {"best_match": "exact_game_name", "path": "exact_path_from_results", "found": true, "reason": "why_this_match"}

            If NO reasonable match found: {"found": false, "reason": "no_games_match_request"}
            """
        } else {
            staticRules = """
            FUZZY MATCHING RULES:
            - Ignore punctuation differences (: vs , vs -)
            - Ignore word order ("The Legend" vs "Legend, The")
            - Handle abbreviations (Bros = Brothers, 3 = III, 2 = II)
            - Regional awareness: Prefer USA versions unless user specifies region

            PHASE 1: BEST VERSION SELECTION (when same game appears on multiple systems)
            If the target game exists on multiple systems (e.g., Space Harrier on 32X, TurboGrafx-16, Amiga):

            1. **Determine which system has the best version** using:
               - Your knowledge of game ports and their quality differences
               - Modern retro gaming community consensus (YouTubers, Digital Foundry, influencers)
               - Technical factors: graphics quality, sound quality, load times, added features
               - Gameplay refinements and content differences between versions

            2. **Consider user's system preferences**:
               - If user has DISLIKED multiple games from a specific system, avoid that system's version
               - If user has FAVORITED games from a system, slightly prefer that system's version
               - Exception: If the best version is clearly superior (e.g., arcade version is definitive), pick it anyway
               - If user explicitly requested a system ("play on TurboGrafx"), ALWAYS honor that request

            3. **Make your determination**:
               - Example: "Contra NES > Contra Arcade" (NES has better level design, 2-player co-op)
               - Example: "Space Harrier 32X > Space Harrier TG16" (32X has arcade-quality graphics/sound)
               - Example: "Mortal Kombat Trilogy N64 > PSX" (N64 has no loading times, tournament standard)
               - Example: "Castlevania SNES > Castlevania Genesis" (SNES has better sound chip)

            🚨 CRITICAL: YOU MUST PICK A GAME IF IT EXISTS IN THE RESULTS
            - Even if all available versions are considered "bad ports" or "inferior versions"
            - Pick the BEST of what's available, even if none are ideal
            - Only return {"found": false} if the game literally doesn't exist in search results
            - Example: If only Game Boy and Game Gear versions exist, pick the better of those two

            PHASE 2: ROM QUALITY SELECTION (once system is chosen)
            After determining the best system version, pick the best ROM dump:
            1. Prefer [!] verified dumps over unverified
            2. Prefer (USA) or (World) versions for English content
            3. If user mentions region/language, prioritize that

            RETURN FORMAT (JSON only):
            {"best_match": "exact_game_name", "path": "exact_path_from_results", "found": true, "reason": "why_this_version_and_rom"}

            Examples:
            - {"best_match": "Space Harrier (JU)", "path": "Sega32X/...", "found": true, "reason": "32X version has arcade-quality graphics and sound, superior to TG16 port"}
            - {"best_match": "Contra (USA)", "path": "NES/...", "found": true, "reason": "NES version has refined level design and co-op gameplay over arcade"}

            If NO match found: {"found": false, "reason": "Could not find [game name] in search results"}
            """
        }

        return """
        \(staticRules)
        \(preferencesSection)\(avoidListSection)

        SEARCH RESULTS FOUND:
        \(formattedResults)

        CLASSIFY identified target: "\(target)"
        User said: "\(userMessage)"

        \(taskDescription)\(mustPick ? """

        🚨 CRITICAL - YOLO FALLBACK MODE: YOU MUST SELECT A GAME
        - You CANNOT return {"found": false} in this mode
        - This is the final fallback - all games from the system are shown above
        - If all games are recently played, pick the best match for the user's request anyway
        - Pick the highest quality ROM (prefer [!] USA versions) that best matches user intent
        - When in doubt, pick a game you don't recognize to give the user new experiences
        - YOU MUST RETURN A VALID GAME SELECTION - NO EXCEPTIONS
        """ : "")
        """
    }

    /// Build specialized VERSION SWITCH game selection prompt
    /// PURPOSE: Pick the SAME GAME on a different platform/region, NOT a different game
    /// OPTIMIZED FOR CACHING: Static content first, dynamic content last
    private func buildVersionSwitchSelectionPrompt(
        games: [String: String],
        target: String,
        userMessage: String,
        currentSystem: String,
        mustPick: Bool = false
    ) async -> String {
        // Format games list
        let sortedGames = games.sorted { $0.key < $1.key }
        var formattedResults = ""

        for (index, (name, path)) in sortedGames.enumerated() {
            formattedResults += "\(index + 1). \"\(name)\" at path: \(path)\n"
        }

        // CACHING OPTIMIZATION: Static rules first (~1200 tokens cached), dynamic content last (~500 tokens uncached)
        return """
        YOU ARE A VERSION SELECTOR. User is playing a game and wants a version on a different platform/region.

        **MATCHING STRATEGY:**

        When user specifies a platform (e.g., "NES version", "Game Boy version", "arcade version"):
        1. **Match the franchise/series** from currently playing game
        2. **Match the requested platform** from user's request
        3. **Pick the best available game** that satisfies both

        **WHAT COUNTS AS SAME FRANCHISE:**
        ✅ "Zelda" on SNES → "Zelda" on Game Boy (any Zelda game is valid)
        ✅ "Tetris" on N64 → "Tetris" on NES (any Tetris variant is valid)
        ✅ "Street Fighter" on SNES → "Street Fighter" on Arcade (any SF game is valid)
        ✅ "Mario" on N64 → "Mario" on NES (any Mario game is valid)
        ❌ "Street Fighter" → "Mortal Kombat" (different franchise entirely)
        ❌ "Zelda" → "Final Fantasy" (different franchise)

        **PRIORITY ORDER FOR SELECTION:**

        1. **Exact title match** (if available):
           - "Dr. Mario" → "Dr. Mario" ✅ (perfect match)
           - Strip region tags: (USA), (Japan), (U), (E), (J), [!], etc.
           - Ignore punctuation: "Zelda: Link's Awakening" = "Zelda - Link's Awakening"

        2. **Franchise match on requested platform** (if no exact title):
           - Currently playing: "The New Tetris" (N64)
           - User wants: "NES version"
           - Available: "Tetris (USA)", "Tetris 2 (USA)"
           - → Pick: "Tetris (USA)" ✅ (best franchise match on NES)

        3. **Quality selection** (when multiple franchise matches exist):
           - Prefer: [!] verified dumps, (USA)/(U) region, English language
           - Avoid: [b] bad dumps, [p] pirate, [h] hacks
           - Pick the most well-known/popular title in franchise

        **SPECIAL CASES:**

        - **"Better version" requests** (no platform specified):
          User asks: "best version", "better version", "definitive version"
          **USE YOUR GAMING KNOWLEDGE** - provide specific technical/gameplay reasons why one version is superior
          **SEARCH RESULTS FIRST** - check what's actually available before deciding
          **EXPLAIN WHY** - always include platform-specific improvements in your reason

          Gaming Knowledge Examples:
          • "Street Fighter II" → Arcade has better sound, graphics, and controls than SNES
          • "Zombies Ate My Neighbors" → SNES has full screen, better colors and sound than Genesis
          • "Mortal Kombat" → Arcade is superior due to Genesis having limited colors and sound
          • "Punch Out" → NES version has more expanded, refined gameplay than Arcade original
          • "Contra" → NES version added storyline, deeper gameplay, and better music than Arcade

        - **Regional requests** (same platform, different region):
          "English version" → Find (USA)/(U) ROM on same system
          "Japanese version" → Find (J)/(Japan) ROM on same system

        - **Already on requested platform:**
          Return {"found": false, "reason": "You're already playing the [platform] version"}

        **EXAMPLES:**

        **Example 1: Franchise Match - Different Title**
        Playing: "The New Tetris" (N64)
        User: "Can we play the NES version instead"
        Available: ["Tetris (USA)", "Tetris 2 (USA)"]
        → Pick: "Tetris (USA)" — Tetris franchise on requested NES platform ✅

        **Example 2: Better Version - With Specific Reasoning**
        Playing: "Street Fighter II" (SNES)
        User: "best version please"
        Available: ["Street Fighter II (Arcade)", "Street Fighter II (Genesis)"]
        → Pick: "Street Fighter II (Arcade)"
        Reason: "Arcade version has better sound, graphics, and more responsive controls than SNES" ✅

        **Example 3: Better Version - NES Superior to Arcade**
        Playing: "Punch Out" (Arcade)
        User: "better version?"
        Available: ["Punch Out (NES)", "Super Punch Out (SNES)"]
        → Pick: "Punch Out (NES)"
        Reason: "NES version has more expanded and refined gameplay than the arcade original" ✅

        **Example 4: Already Playing Best Version**
        Playing: "Zombies Ate My Neighbors" (SNES)
        User: "best version?"
        Available: ["Zombies Ate My Neighbors (Genesis)"]
        → Return: {"found": false, "reason": "SNES version is already the best - has full screen, better colors and sound than Genesis"}

        **Example 5: Wrong Franchise**
        Playing: "Street Fighter II" (SNES)
        User: "arcade version"
        Available: ["Mortal Kombat", "NBA Jam"]
        → Return: {"found": false, "reason": "No Street Fighter games found for arcade"}

        **CRITICAL RULES:**
        1. **Franchise match is PRIMARY** - user wants [franchise] on [platform]
        2. **Exact title is BONUS** - prefer it, but not required
        3. **Never switch franchises** - "Zelda" should never become "Mario"
        4. **Honor user's platform request** - if they say NES, give them NES
        5. **Be helpful** - it's OK to return false with clear explanation

        **RETURN FORMAT (JSON only):**
        Success: {"best_match": "exact_game_name", "path": "exact_path_from_results", "found": true, "reason": "why_this_match"}
        Failure: {"found": false, "reason": "Helpful explanation why request cannot be fulfilled"}

        ## SEARCH RESULTS - THESE ARE CANDIDATES (not currently playing)
        \(formattedResults)

        ## WHAT USER IS CURRENTLY PLAYING
        Game: "\(target)"
        Platform: \(currentSystem)
        User request: "\(userMessage)"

        **REMINDER**: The search results above are CANDIDATES you can choose from.
        The user is CURRENTLY on \(currentSystem). Compare CURRENT platform against CANDIDATE platforms.
        """
    }

    /// Execute a single search with dynamic timeout (returns as soon as result arrives OR timeout)
    private func executeSearchWithTimeout(
        searchTerm: String,
        system: String?, // Can be nil to search all systems
        timeout: UInt64 = 500_000_000, // 500ms default
        onCommandGenerated: @escaping (String) -> Void,
        searchID: String? = nil // Optional pre-generated search ID
    ) async throws -> [String: Any] {

        // Fix: Convert string "null" to nil for all-systems search
        let effectiveSystem = (system == "null") ? nil : system

        // Generate ID if not provided (backwards compatible)
        // Note: Must be pure UUID format - MiSTer rejects prefixed IDs like "search_<UUID>"
        let effectiveSearchID = searchID ?? UUID().uuidString
        let normalizedSearchID = effectiveSearchID.lowercased()

        let systemsArray: String
        if let effectiveSystem = effectiveSystem {
            systemsArray = "[\"\(effectiveSystem)\"]"
            #if DEBUG
            print("🚀 Executing search: '\(searchTerm)' on \(effectiveSystem) (timeout: \(timeout / 1_000_000)ms)")
            #endif
        } else {
            systemsArray = "[]"
            #if DEBUG
            print("🚀 Executing search: '\(searchTerm)' on ALL systems (timeout: \(timeout / 1_000_000)ms)")
            #endif
        }

        let searchCommand = """
        {"jsonrpc":"2.0","id":"\(normalizedSearchID)","method":"media.search","params":{"query":"\(searchTerm)","systems":\(systemsArray)}}
        """

        // DYNAMIC TIMEOUT: Race between result arrival and timeout
        // Returns immediately when result arrives, or after timeout if no result
        let startTime = Date()

        do {
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    // Register continuation for this specific search ID
                    let registrationOutcome = await self.searchResultManager.registerContinuation(
                        continuation,
                        for: normalizedSearchID
                    )

                    if case .fulfilledFromBuffer = registrationOutcome {
                        #if DEBUG
                        print("⚡️ Search \(normalizedSearchID) fulfilled immediately from buffered result")
                        #endif
                        return
                    }

                    // Send the search command
                    onCommandGenerated(searchCommand)

                    // Start timeout watchdog
                    Task {
                        try await Task.sleep(nanoseconds: timeout)

                        // Try to resume with timeout error
                        let timeoutOutcome = await self.searchResultManager.handleTimeout(for: normalizedSearchID)
                        if case .resumedWithTimeout = timeoutOutcome {
                            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                            #if DEBUG
                            print("⏰ Search timed out after \(elapsed)ms")
                            print("   Search ID: \(normalizedSearchID) marked as abandoned")
                            #endif
                        }
                        // If continuation was already resumed by result, this does nothing
                    }
                    // Result will resume continuation via captureSearchResult() when it arrives
                }
            }
        } catch {
            // Timeout or other error propagated from continuation
            throw error
        }
    }

    /// Execute YOLO search independently - bypasses batch validation
    /// Used as fallback when 3-search batch returns no results
    /// Returns results directly via continuation without batch tracking
    private func executeYoloSearchDirect(
        system: String?,
        timeout: UInt64 = 15_000_000_000, // 15 seconds default
        onCommandGenerated: @escaping (String) -> Void
    ) async throws -> [String: Any] {

        // Generate unique search ID for YOLO - use standard UUID format (no prefix)
        // MiSTer rejects prefixed IDs like "yolo_<UUID>" with -32600 error
        let yoloSearchID = UUID().uuidString.lowercased()

        let systemsArray: String
        if let system = system {
            systemsArray = "[\"\(system)\"]"
            #if DEBUG
            print("🎯 YOLO Search: Empty query on \(system) (timeout: \(timeout / 1_000_000_000)s)")
            #endif
        } else {
            systemsArray = "[]"
            #if DEBUG
            print("🎯 YOLO Search: Empty query on ALL systems (timeout: \(timeout / 1_000_000_000)s)")
            #endif
        }

        let searchCommand = """
        {"jsonrpc":"2.0","id":"\(yoloSearchID)","method":"media.search","params":{"query":"","systems":\(systemsArray)}}
        """

        // Use withCheckedThrowingContinuation for direct result capture
        // This bypasses batch validation in ContentView
        let startTime = Date()

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                // Register continuation for this YOLO search
                let registrationOutcome = await self.searchResultManager.registerContinuation(
                    continuation,
                    for: yoloSearchID
                )

                if case .fulfilledFromBuffer = registrationOutcome {
                    #if DEBUG
                    print("⚡️ YOLO search \(yoloSearchID) fulfilled immediately from buffer")
                    #endif
                    return
                }

                // Send the YOLO search command
                #if DEBUG
                print("📤 Sending YOLO search command: \(yoloSearchID)")
                #endif
                onCommandGenerated(searchCommand)

                // Start timeout watchdog
                Task {
                    try await Task.sleep(nanoseconds: timeout)

                    // Try to resume with timeout error
                    let timeoutOutcome = await self.searchResultManager.handleTimeout(for: yoloSearchID)
                    if case .resumedWithTimeout = timeoutOutcome {
                        let elapsed = Int(Date().timeIntervalSince(startTime))
                        #if DEBUG
                        print("⏰ YOLO search timed out after \(elapsed)s")
                        #endif
                    }
                }
                // Result will resume continuation via captureSearchResult() when it arrives
            }
        }
    }

    /// Capture search result from ContentView and fulfill pending continuation
    func captureSearchResult(_ result: [String: Any], searchID: String) {
        let normalizedID = searchID.lowercased()
        #if DEBUG
        print("🚀 Captured search result for \(normalizedID): \(result.keys.joined(separator: ", "))")
        #endif

        Task {
            let outcome = await searchResultManager.handleResult(result, for: normalizedID)
            #if DEBUG
            switch outcome {
            case .resumedActiveContinuation:
                print("✅ Successfully resumed continuation for \(normalizedID)")
            case .bufferedAfterTimeout:
                print("⚠️ Result buffered for \(normalizedID) after timeout")
            case .bufferedAwaitingContinuation:
                print("⏱️ Result buffered for \(normalizedID) awaiting continuation")
            }
            #endif
        }
    }
    
    /// Execute searches sequentially and collect all results
    private func executeSearchesSequentially(
        searchTerms: [String],
        system: String?, // Can be nil to search all systems
        onCommandGenerated: @escaping (String) -> Void
    ) async throws -> [[String: Any]] {

        // Create batch and pre-generate search IDs
        // Note: Must be pure UUID format - MiSTer rejects prefixed IDs like "search_<UUID>"
        let searchIDs = searchTerms.map { _ in UUID().uuidString.lowercased() }
        let batch = SearchBatch(
            batchID: UUID(),
            searchIDs: Set(searchIDs),
            actionType: threeCallContext?.actionType ?? "unknown",
            createdAt: Date()
        )

        // Store as active batch (invalidates any previous batch)
        activeSearchBatch = batch

        #if DEBUG
        print("🆕 Created search batch: \(batch.batchID) with \(searchIDs.count) searches")
        print("   Action type: \(batch.actionType)")
        print("   Search IDs: \(searchIDs.joined(separator: ", "))")
        #endif

        var immediateSuccessCount = 0
        let batchStartTime = Date()

        // Guard timer configuration based on system type
        let isNullSystemSearch = (system == nil)
        let guardTimerDuration: TimeInterval = isNullSystemSearch ? 5.1 : 3.5
        let search1Timeout: UInt64 = isNullSystemSearch ? 15_000_000_000 : 5_100_000_000  // 15s null, 5.1s system
        let subsequentSearchTimeout: UInt64 = 1_700_000_000  // 1.7s for Search 2 & 3

        // Start guard timer
        let guardTimerStart = Date()

        #if DEBUG
        print("🚀 Starting sequential execution of \(searchTerms.count) searches")
        print("⏱️ Guard timer: \(guardTimerDuration)s (null system: \(isNullSystemSearch))")
        print("⏱️ Search 1 timeout: \(isNullSystemSearch ? "15s" : "5.1s"), Search 2/3 timeout: 1.7s")
        #endif

        // ===== SEARCH 1 =====
        if searchTerms.count > 0 {
            let searchID = searchIDs[0]
            let searchStartTime = Date()

            do {
                let result = try await executeSearchWithTimeout(
                    searchTerm: searchTerms[0],
                    system: system,
                    timeout: search1Timeout,
                    onCommandGenerated: onCommandGenerated,
                    searchID: searchID
                )

                let searchDuration = Date().timeIntervalSince(searchStartTime)
                immediateSuccessCount += 1

                #if DEBUG
                print("🚀 Search 1/\(searchTerms.count) completed in \(Int(searchDuration * 1000))ms: \(result.keys.count) keys")
                #endif

            } catch {
                #if DEBUG
                print("🚀 Search 1/\(searchTerms.count) failed: \(error)")
                #endif
            }

            // CHECKPOINT: Check cancellation after Search 1
            guard !isCancellationRequested else {
                AppLogger.standard("🛑 Cancellation detected after Search 1 - aborting remaining searches")
                activeSearchBatch = nil
                await searchResultManager.clear(searchIDs: searchIDs)
                throw CancellationError()
            }

            // Check guard timer after Search 1
            let elapsed1 = Date().timeIntervalSince(guardTimerStart)
            if elapsed1 >= guardTimerDuration {
                AppLogger.standard("⏰ 3-search guard timer expired (\(String(format: "%.1f", elapsed1))s) - executed \(immediateSuccessCount) of \(searchTerms.count) searches")
                #if DEBUG
                print("⏭️ Guard timer expired (\(String(format: "%.1f", elapsed1))s) - skipping remaining searches")
                #endif

                // Mark batch as completed BEFORE aggregating results
                // This allows late results to still be captured before batch is invalidated
                activeSearchBatch?.isCompleted = true

                // Proceed to aggregate results with what we have
                let aggregatedResults = await searchResultManager.results(inOrder: searchIDs)

                #if DEBUG
                let totalDuration = Date().timeIntervalSince(batchStartTime)
                print("🚀 Sequential search complete (guard expired): \(aggregatedResults.count)/\(searchTerms.count) results captured (immediate successes: \(immediateSuccessCount)) (total: \(Int(totalDuration * 1000))ms)")
                #endif

                // Clear batch after results aggregated
                activeSearchBatch = nil
                await searchResultManager.clear(searchIDs: searchIDs)
                #if DEBUG
                print("✅ Cleared search batch after completion")
                #endif

                return aggregatedResults
            }
        }

        // ===== SEARCH 2 =====
        if searchTerms.count > 1 {
            let searchID = searchIDs[1]
            let searchStartTime = Date()

            do {
                let result = try await executeSearchWithTimeout(
                    searchTerm: searchTerms[1],
                    system: system,
                    timeout: subsequentSearchTimeout,
                    onCommandGenerated: onCommandGenerated,
                    searchID: searchID
                )

                let searchDuration = Date().timeIntervalSince(searchStartTime)
                immediateSuccessCount += 1

                #if DEBUG
                print("🚀 Search 2/\(searchTerms.count) completed in \(Int(searchDuration * 1000))ms: \(result.keys.count) keys")
                #endif

            } catch {
                #if DEBUG
                print("🚀 Search 2/\(searchTerms.count) failed: \(error)")
                #endif
            }

            // CHECKPOINT: Check cancellation after Search 2
            guard !isCancellationRequested else {
                AppLogger.standard("🛑 Cancellation detected after Search 2 - aborting remaining searches")
                activeSearchBatch = nil
                await searchResultManager.clear(searchIDs: searchIDs)
                throw CancellationError()
            }

            // Check guard timer after Search 2
            let elapsed2 = Date().timeIntervalSince(guardTimerStart)
            if elapsed2 >= guardTimerDuration {
                AppLogger.standard("⏰ 3-search guard timer expired (\(String(format: "%.1f", elapsed2))s) - executed \(immediateSuccessCount) of \(searchTerms.count) searches")
                #if DEBUG
                print("⏭️ Guard timer expired (\(String(format: "%.1f", elapsed2))s) - skipping Search 3")
                #endif

                // Mark batch as completed BEFORE aggregating results
                // This allows late results to still be captured before batch is invalidated
                activeSearchBatch?.isCompleted = true

                // Proceed to aggregate results with what we have
                let aggregatedResults = await searchResultManager.results(inOrder: searchIDs)

                #if DEBUG
                let totalDuration = Date().timeIntervalSince(batchStartTime)
                print("🚀 Sequential search complete (guard expired): \(aggregatedResults.count)/\(searchTerms.count) results captured (immediate successes: \(immediateSuccessCount)) (total: \(Int(totalDuration * 1000))ms)")
                #endif

                // Clear batch after results aggregated
                activeSearchBatch = nil
                await searchResultManager.clear(searchIDs: searchIDs)
                #if DEBUG
                print("✅ Cleared search batch after completion")
                #endif

                return aggregatedResults
            }
        }

        // ===== SEARCH 3 =====
        if searchTerms.count > 2 {
            let searchID = searchIDs[2]
            let searchStartTime = Date()

            do {
                let result = try await executeSearchWithTimeout(
                    searchTerm: searchTerms[2],
                    system: system,
                    timeout: subsequentSearchTimeout,
                    onCommandGenerated: onCommandGenerated,
                    searchID: searchID
                )

                let searchDuration = Date().timeIntervalSince(searchStartTime)
                immediateSuccessCount += 1

                #if DEBUG
                print("🚀 Search 3/\(searchTerms.count) completed in \(Int(searchDuration * 1000))ms: \(result.keys.count) keys")
                #endif

            } catch {
                #if DEBUG
                print("🚀 Search 3/\(searchTerms.count) failed: \(error)")
                #endif
            }

            // CHECKPOINT: Check cancellation after Search 3
            guard !isCancellationRequested else {
                AppLogger.standard("🛑 Cancellation detected after Search 3 - aborting result processing")
                activeSearchBatch = nil
                await searchResultManager.clear(searchIDs: searchIDs)
                throw CancellationError()
            }
        }

        // Mark batch as completed BEFORE aggregating results
        // This allows late results to still be captured before batch is invalidated
        activeSearchBatch?.isCompleted = true

        let aggregatedResults = await searchResultManager.results(inOrder: searchIDs)

        #if DEBUG
        let totalDuration = Date().timeIntervalSince(batchStartTime)
        print("🚀 Sequential search complete: \(aggregatedResults.count)/\(searchTerms.count) results captured (immediate successes: \(immediateSuccessCount)) (total: \(Int(totalDuration * 1000))ms)")
        #endif

        // Clear batch after results aggregated
        activeSearchBatch = nil
        await searchResultManager.clear(searchIDs: searchIDs)
        #if DEBUG
        print("✅ Cleared search batch after completion")
        #endif

        return aggregatedResults
    }
    
    /// Execute optimized search using strategy pattern
    private func executeOptimizedSearch(
        strategy: OptimizedSearchStrategy,
        context: ThreeCallContext,
        apiKey: String,
        onCommandGenerated: @escaping (String) -> Void,
        onCommandExecuted: @escaping (String) -> Void
    ) async throws -> ThreeCallContext {
        
        // Set flag to prevent old retry logic from engaging
        isUsingOptimizedSearch = true
        currentSearchStrategy = strategy

        #if DEBUG
        print("🚀 OPTIMIZED SEARCH: Starting with \(String(describing: type(of: strategy))) strategy")
        #endif

        // CHECKPOINT: Check cancellation before expensive search term generation
        guard !isCancellationRequested else {
            AppLogger.standard("🛑 Cancellation detected before search term generation - aborting")
            throw CancellationError()
        }

        // Phase 1: Generate search terms (ONE LLM call)
        #if DEBUG
        print("🚀 Phase 1: Generating search terms")
        #endif
        let searchTermsTask = strategy.buildSearchTermsPrompt(context: context)

        // Build enriched user message with preferences and context
        let enrichedUserMessage = await strategy.buildEnrichedUserMessage(context: context)

        // Combine task and enriched message for user prompt (cache optimization: task first, dynamic content last)
        let combinedUserPrompt = searchTermsTask + "\n\n" + enrichedUserMessage

        let requestBody: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0.2,
            "max_tokens": 200,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": getConsolidatedCallA_SystemPrompt()],  // CONSOLIDATED: Enables caching
                ["role": "user", "content": combinedUserPrompt]
            ]
        ]
        
        let response = try await makeOpenAIRequest(callPhase: "A-SearchTerms", context: "executeOptimizedSearch-phase1", requestBody: requestBody, apiKey: apiKey)

        // CHECKPOINT: Check cancellation after search terms API call completes
        guard !isCancellationRequested else {
            AppLogger.standard("🛑 Cancellation detected after search terms generation - aborting search")
            throw CancellationError()
        }

        // Log the raw response for console.app
        if let content = extractContentFromResponse(response) {
            AppLogger.aiResponseWithDetail(
                phase: "A-SearchTerms",
                response: "🤖 Raw AI Response: \(content)"
            )
        }
        
        // Parse search terms response
        guard let content = extractContentFromResponse(response),
              let data = content.data(using: .utf8),
              let searchTermsData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let searches = searchTermsData["searches"] as? [String],
              let targetGame = searchTermsData["target_game"] as? String
        else {
            #if DEBUG
            print("❌ OPTIMIZED SEARCH: Failed to parse search terms response")
            #endif
            throw NSError(domain: "OptimizedSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse search terms"])
        }

        // Handle null system (search all systems when not specified)
        let targetSystem = searchTermsData["system"] as? String

        #if DEBUG
        print("🚀 Generated search terms: \(searches)")
        print("🚀 Target game: \(targetGame)")
        print("🚀 Target system: \(targetSystem ?? "nil")")
        #endif

        // Update status to show we're searching
        Task { @MainActor in
            if searches.count == 1 {
                uiStateService?.showStatus("Searching for \(searches[0])...")
            } else {
                uiStateService?.showStatus("Searching for \(targetGame)...")
            }
        }

        // Phase 2: Execute searches sequentially and collect results
        #if DEBUG
        print("🚀 Search Pattern: EXECUTE (\(searches.count) searches sequentially)")
        #endif
        let allResults = try await executeSearchesSequentially(
            searchTerms: searches,
            system: targetSystem, // Can be nil - handled in executeSearchesSequentially
            onCommandGenerated: onCommandGenerated
        )

        // Phase 3: Process results using strategy
        #if DEBUG
        print("🚀 Phase 3: Processing results with strategy")
        #endif
        let decision = try await strategy.processSearchResults(
            context: context,
            searchResults: allResults,
            targetGame: targetGame,
            targetSystem: targetSystem ?? "all",
            apiKey: apiKey
        )

        // Phase 4: Execute decision
        AppLogger.emit(type: .launchRouting, content: "Phase 4: Executing decision")
        var updatedContext = context

        // Store search context for follow-up requests (must be done AFTER updatedContext is created)
        updatedContext.targetGame = targetGame
        updatedContext.lastSearchSystem = targetSystem
        #if DEBUG
        print("🚀 Stored search context for follow-ups: game=\(targetGame), system=\(targetSystem ?? "nil")")
        #endif
        
        switch decision {
        case .launchExact(let game, let command, let selectionReason):
            AppLogger.emit(type: .launchRouting, content: "Decision: Launch exact game '\(game)'")
            // Preserve pathway type - ensure recommend_confirm and version_switch remain for specialized Call B prompts
            if currentSearchStrategy is LaunchRecommendedStrategy {
                if context.actionType == "recommend_confirm" {
                    updatedContext.actionType = "recommend_confirm"
                    updatedContext.actionContext = "Recommended exact match (confirmation): \(game)"
                } else {
                    updatedContext.actionType = "recommend"
                    updatedContext.actionContext = "Recommended exact match: \(game)"
                }
            } else if currentSearchStrategy is VersionSwitchStrategy {
                // Preserve version_switch actionType so Call B can use specialized prompt with AI reasoning
                updatedContext.actionType = "version_switch"
                updatedContext.actionContext = "Version switched: \(game)"
            } else {
                updatedContext.actionType = "launch_specific_exact"
                updatedContext.actionContext = "Launching exact match: \(game)"
            }

            // Execute the launch command
            onCommandExecuted("Launching exact match: \(game)")
            generatedCommand = command  // Set for UI display
            onCommandGenerated(command)

            // Set up deferred response system (like normal direct launches)
            pendingContext = updatedContext
            pendingExecutionResult = "Launching exact match: \(game)"
            pendingApiKey = apiKey
            pendingSelectionReason = selectionReason  // Store AI's reasoning for Call B (version_switch uses this)
            pendingStrategy = strategy  // Store strategy for specialized Call B prompt
            pendingDecision = decision  // Store decision for strategy's Call B prompt
            
        case .gameNotFound(let searched, let suggestions):
            AppLogger.emit(type: .launchRouting, content: "Decision: Game not found '\(searched)' - \(suggestions.count) suggestions")
            
            // Check if this is a recommendation strategy that supports yolo search
            if currentSearchStrategy is LaunchRecommendedStrategy {
                AppLogger.standard("🔍 Zero results from 3-search batch - falling back to YOLO search")
                AppLogger.emit(type: .launchRouting, content: "Executing yolo search for recommendation fallback (optimized)")

                // YOLO SEARCH: Independent direct await with 15-second timeout
                // This bypasses batch validation - results arrive directly via continuation
                do {
                    let yoloStartTime = Date()
                    let yoloResult = try await executeYoloSearchDirect(
                        system: targetSystem,
                        timeout: 15_000_000_000, // 15 seconds for YOLO
                        onCommandGenerated: onCommandGenerated
                    )
                    let yoloDuration = Date().timeIntervalSince(yoloStartTime)
                    AppLogger.standard("✅ YOLO search completed in \(String(format: "%.1f", yoloDuration))s")

                    // Parse results
                    let results = yoloResult["results"] as? [[String: Any]] ?? []
                    if results.isEmpty {
                        // Nothing available even via YOLO → provide helpful not found response
                        AppLogger.standard("❌ YOLO search returned 0 games")
                        updatedContext.actionType = "game_not_found"
                        updatedContext.actionContext = "Could not find: \(targetGame)"
                        let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: [])
                        let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                        if callBPrompt != "SKIP_CALL_B" {
                            let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                            updatedContext.coolUncleResponse = callBResponse
                            onCommandExecuted("Game not found: \(targetGame)")
                        }
                    } else {
                        AppLogger.standard("✅ YOLO search found \(results.count) games")
                        // Flatten into name->path map (first occurrence wins)
                        var games: [String: String] = [:]
                        for game in results {
                            if let name = game["name"] as? String,
                               let path = game["path"] as? String,
                               games[name] == nil {
                                games[name] = path
                            }
                        }

                        // Filter out system utility files
                        games = filterSystemUtilityFiles(games)
                        AppLogger.standard("🎮 After filtering: \(games.count) playable games")

                        // Ask AI to pick best recommendation from YOLO results
                        let (selectedGame, selectedPath, _) = try await executeCallGameSelection(
                            availableGames: games,
                            targetGame: targetGame,
                            userMessage: context.userMessage,
                            actionType: "recommend",
                            mustPick: true, // Force AI to pick something from YOLO results
                            apiKey: apiKey
                        )

                        if let game = selectedGame, let path = selectedPath {
                            AppLogger.standard("🎯 AI selected from YOLO results: \(game)")
                            // Launch selected game (use Amiga listing escape only where needed)
                            let launchText = path.contains("Amiga/listings/") ? "**launch:\(path)" : path
                            let command = """
                            {"jsonrpc":"2.0","id":"","method":"launch","params":{"text":"\(launchText)"}}
                            """

                            updatedContext.actionType = "recommend"
                            updatedContext.actionContext = "AI recommended and launching: \(game)"

                            onCommandExecuted("AI selected and launching: \(game)")
                            generatedCommand = command  // Set for UI display
                            onCommandGenerated(command)

                            // Set up deferred response like other launches
                            pendingContext = updatedContext
                            pendingExecutionResult = "AI selected and launching: \(game)"
                            pendingApiKey = apiKey
                        } else {
                            // Selection failed → provide not found guidance
                            AppLogger.standard("❌ AI could not select game from YOLO results")
                            updatedContext.actionType = "game_not_found"
                            updatedContext.actionContext = "AI could not find: \(targetGame)"
                            let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: Array(games.keys.prefix(3)))
                            let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                            if callBPrompt != "SKIP_CALL_B" {
                                let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                                updatedContext.coolUncleResponse = callBResponse
                                onCommandExecuted("AI could not find: \(targetGame)")
                            }
                        }
                    }
                } catch is SearchTimeoutError {
                    // YOLO search timed out after 15 seconds
                    AppLogger.standard("⏰ YOLO search timed out after 15 seconds")
                    updatedContext.actionType = "game_not_found"
                    updatedContext.actionContext = "Search timeout: \(targetGame)"

                    // Generate user-friendly timeout message
                    let timeoutMessage = "Wow, I searched for a while and couldn't find any games. The system might be slow to respond right now."
                    updatedContext.coolUncleResponse = timeoutMessage

                    // Hide transient status, add assistant bubble (Consumer UI integration)
                    Task { @MainActor in
                        uiStateService?.hideStatus()
                        chatBubbleService?.addAssistantMessage(timeoutMessage)
                    }

                    onCommandExecuted("YOLO search timeout")
                } catch {
                    // YOLO search failed (network or other error)
                    AppLogger.standard("❌ YOLO search failed: \(error)")
                    updatedContext.actionType = "game_not_found"
                    updatedContext.actionContext = "Could not find: \(targetGame)"
                    let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: [])
                    let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                    if callBPrompt != "SKIP_CALL_B" {
                        let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                        updatedContext.coolUncleResponse = callBResponse
                        onCommandExecuted("Game not found: \(targetGame)")
                    }
                }
            } else {
                // Handle normal game not found (for LaunchSpecificStrategy - direct launches should fail)
                updatedContext.actionType = "game_not_found"
                updatedContext.actionContext = "Could not find: \(searched)"
                
                // Generate Call B response for game not found
                let callBPrompt = strategy.buildCallBPrompt(decision: decision, context: context)
                if callBPrompt != "SKIP_CALL_B" {
                    let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                    updatedContext.coolUncleResponse = callBResponse
                    onCommandExecuted("Game not found: \(searched)")
                }
            }
            
        case .needsAISelection(let games, let targetGame, let userMessage):
            AppLogger.emit(type: .launchRouting, content: "Decision: Needs AI selection - \(games.count) candidates found")
            
            // Determine action type based on current strategy if context doesn't have it
            let effectiveActionType: String
            if let contextActionType = context.actionType {
                effectiveActionType = contextActionType
            } else if currentSearchStrategy is LaunchRecommendedStrategy {
                effectiveActionType = "recommend"
                #if DEBUG
                print("🔧 FIXED: Using 'recommend' actionType for LaunchRecommendedStrategy")
                #endif
            } else {
                effectiveActionType = "launch_specific"
            }
            
            // Update pending context with correct actionType for deferred response
            updatePendingContextActionType(effectiveActionType)
            
            // Use AI to select the best game
            let (selectedGame, selectedPath, failureReason) = try await executeCallGameSelection(
                availableGames: games,
                targetGame: targetGame,
                userMessage: userMessage,
                actionType: effectiveActionType,
                currentSystem: context.gameContextSnapshot.currentSystem,
                apiKey: apiKey
            )

            if let game = selectedGame, let path = selectedPath {
                // AI found a match
                #if DEBUG
                print("🚀 AI Selected: '\(game)'")
                #endif
                // Only add **launch: prefix for Amiga listings, use raw path for all other systems
                let launchText = path.contains("Amiga/listings/") ? "**launch:\(path)" : path
                let command = """
                {"jsonrpc":"2.0","id":"","method":"launch","params":{"text":"\(launchText)"}}
                """

                if currentSearchStrategy is LaunchRecommendedStrategy {
                    if context.actionType == "recommend_confirm" {
                        // Confirmation flow: DO NOT launch. Cache and prompt for confirmation.
                        updatedContext.actionType = "recommend_confirm"
                        updatedContext.actionContext = "Selected recommendation for confirmation: \(game)"
                        // Expose the command to Call B routing while preventing execution
                        updatedContext.jsonCommand = command
                        // Cache recommendation immediately to avoid races
                        setPendingRecommendation(command: command, gameName: game)
                        // Provide deterministic execution result so routing can detect cached state
                        commandExecutionResult = "Recommendation cached - awaiting confirmation"
                        onCommandExecuted("Recommendation cached - awaiting confirmation")
                        // IMPORTANT: Do NOT call onCommandGenerated(command) — avoid sending to MiSTer
                        // Generate the confirmation prompt now so optimized path can return early with speech ready
                        var confirmContext = updatedContext
                        confirmContext.needsSalesPitch = false
                        confirmContext = try await executeCallB_SpeechGeneration(
                            context: confirmContext,
                            executionResult: "Ready to launch \(game)",
                            apiKey: apiKey
                        )
                        updatedContext = confirmContext
                    } else {
                        // Normal recommend flow: launch immediately
                        updatedContext.actionType = "recommend"
                        updatedContext.actionContext = "AI recommended and launching: \(game)"
                        onCommandExecuted("AI selected and launching: \(game)")
                        generatedCommand = command  // Set for UI display
                        onCommandGenerated(command)
                        // Set up deferred response system (like normal direct launches)
                        pendingContext = updatedContext
                        pendingExecutionResult = "AI selected and launching: \(game)"
                        pendingApiKey = apiKey
                        pendingSelectionReason = failureReason // Store AI's selection reasoning for Call B
                    }
                } else if currentSearchStrategy is VersionSwitchStrategy {
                    // version_switch path - preserve actionType for specialized Call B prompt
                    updatedContext.actionType = "version_switch"
                    updatedContext.actionContext = "AI selected version: \(game)"
                    onCommandExecuted("AI selected and launching: \(game)")
                    generatedCommand = command  // Set for UI display
                    onCommandGenerated(command)
                    pendingContext = updatedContext
                    pendingExecutionResult = "AI selected and launching: \(game)"
                    pendingApiKey = apiKey
                    pendingSelectionReason = failureReason // Store AI's selection reasoning for Call B
                    pendingStrategy = strategy  // Store strategy for specialized Call B prompt
                    pendingDecision = .launchExact(game: game, command: command, reason: failureReason)  // Create decision for strategy's Call B prompt
                } else {
                    // launch_specific path
                    updatedContext.actionType = "launch_specific_exact"
                    updatedContext.actionContext = "AI selected and launching: \(game)"
                    onCommandExecuted("AI selected and launching: \(game)")
                    generatedCommand = command  // Set for UI display
                    onCommandGenerated(command)
                    pendingContext = updatedContext
                    pendingExecutionResult = "AI selected and launching: \(game)"
                    pendingApiKey = apiKey
                    pendingSelectionReason = failureReason // Store AI's selection reasoning for Call B
                }
            } else {
                // AI couldn't find a match - check if we should try YOLO fallback
                #if DEBUG
                print("🚀 AI Selection: No match found")
                #endif

                // If this is version_switch, use the helpful failure reason from AI (no YOLO fallback)
                if currentSearchStrategy is VersionSwitchStrategy {
                    AppLogger.emit(type: .launchRouting, content: "Version switch failed: \(failureReason ?? "No match")")
                    updatedContext.actionType = "version_switch_failed"
                    updatedContext.actionContext = failureReason ?? "Could not find requested version"

                    // Pass failure reason to Call B via gameNotFound (suggestions array holds the reason)
                    let notFoundDecision = SearchDecision.gameNotFound(
                        searched: targetGame,
                        suggestions: [failureReason ?? "Could not find requested version"]
                    )
                    let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                    if callBPrompt != "SKIP_CALL_B" {
                        let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                        updatedContext.coolUncleResponse = callBResponse
                        onCommandExecuted("Version switch failed: \(failureReason ?? "No match")")
                    }
                } else if currentSearchStrategy is LaunchRecommendedStrategy {
                    // If this is a recommendation strategy, try YOLO search as fallback
                    AppLogger.emit(type: .launchRouting, content: "AI selection failed - executing YOLO fallback for recommendation")

                    do {
                        // Execute YOLO search to get ALL games for this system
                        let yoloResult = try await executeSearchWithTimeout(
                            searchTerm: "",
                            system: targetSystem,
                            timeout: 1_500_000_000, // 1500ms for YOLO
                            onCommandGenerated: onCommandGenerated
                        )

                        // Parse YOLO results
                        let results = yoloResult["results"] as? [[String: Any]] ?? []
                        if results.isEmpty {
                            // Nothing available even via YOLO → provide helpful not found response
                            AppLogger.emit(type: .launchRouting, content: "YOLO returned 0 games for system \(targetSystem ?? "unknown")")
                            updatedContext.actionType = "game_not_found"
                            updatedContext.actionContext = "No games available on system"
                            let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: [])
                            let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                            if callBPrompt != "SKIP_CALL_B" {
                                let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                                updatedContext.coolUncleResponse = callBResponse
                                onCommandExecuted("No games available: \(targetGame)")
                            }
                        } else {
                            // Flatten into name->path map (first occurrence wins)
                            var rawGames: [String: String] = [:]
                            for game in results {
                                if let name = game["name"] as? String,
                                   let path = game["path"] as? String,
                                   rawGames[name] == nil {
                                    rawGames[name] = path
                                }
                            }

                            // Filter out system utility files (mister-boot, etc.)
                            let yoloGames = filterSystemUtilityFiles(rawGames)
                            let filteredCount = rawGames.count - yoloGames.count
                            if filteredCount > 0 {
                                AppLogger.emit(type: .launchRouting, content: "YOLO filtered \(filteredCount) system utility files")
                            }

                            AppLogger.emit(type: .launchRouting, content: "YOLO found \(yoloGames.count) games - asking AI to pick with MUST_PICK mode")

                            // Ask AI to pick best recommendation from YOLO results with MUST PICK enforcement
                            let (selectedGame, selectedPath, _) = try await executeCallGameSelection(
                                availableGames: yoloGames,
                                targetGame: targetGame,
                                userMessage: context.userMessage,
                                actionType: "recommend",
                                mustPick: true, // FORCE AI to pick a game
                                apiKey: apiKey
                            )

                            if let game = selectedGame, let path = selectedPath {
                                // Launch selected game
                                let launchText = path.contains("Amiga/listings/") ? "**launch:\(path)" : path
                                let command = """
                                {"jsonrpc":"2.0","id":"","method":"launch","params":{"text":"\(launchText)"}}
                                """

                                AppLogger.emit(type: .launchRouting, content: "YOLO fallback selected: \(game)")

                                // Check if this is recommend_confirm (needs caching) or regular recommend (immediate launch)
                                if context.actionType == "recommend_confirm" {
                                    // Cache recommendation and ask for confirmation
                                    updatedContext.actionType = "recommend_confirm"
                                    updatedContext.actionContext = "YOLO fallback - awaiting confirmation: \(game)"
                                    updatedContext.jsonCommand = command

                                    setPendingRecommendation(command: command, gameName: game)
                                    onCommandExecuted("Recommendation cached - awaiting confirmation")

                                    // Generate confirmation prompt (DO NOT launch yet)
                                    var confirmContext = updatedContext
                                    confirmContext.needsSalesPitch = false
                                    confirmContext = try await executeCallB_SpeechGeneration(
                                        context: confirmContext,
                                        executionResult: "Ready to launch \(game)",
                                        apiKey: apiKey
                                    )
                                    updatedContext = confirmContext
                                } else {
                                    // Regular recommend - launch immediately
                                    updatedContext.actionType = "recommend"
                                    updatedContext.actionContext = "YOLO fallback selected: \(game)"
                                    onCommandExecuted("YOLO fallback launching: \(game)")
                                    generatedCommand = command  // Set for UI display
                                    onCommandGenerated(command)

                                    // Set up deferred response system
                                    pendingContext = updatedContext
                                    pendingExecutionResult = "YOLO fallback launching: \(game)"
                                    pendingApiKey = apiKey
                                }
                            } else {
                                // Even YOLO + mustPick failed (should be impossible)
                                AppLogger.emit(type: .error, content: "❌ CRITICAL: YOLO mustPick=true returned nil with \(yoloGames.count) games available")
                                updatedContext.actionType = "game_not_found"
                                updatedContext.actionContext = "AI could not select from \(yoloGames.count) games"
                                let suggestions = Array(yoloGames.keys.prefix(3))
                                let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: suggestions)
                                let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                                if callBPrompt != "SKIP_CALL_B" {
                                    let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                                    updatedContext.coolUncleResponse = callBResponse
                                    onCommandExecuted("YOLO fallback failed: \(targetGame)")
                                }
                            }
                        }
                    } catch {
                        // YOLO search failed - fall back to original not found behavior
                        AppLogger.emit(type: .launchRouting, content: "YOLO fallback failed: \(error.localizedDescription)")
                        updatedContext.actionType = "game_not_found"
                        updatedContext.actionContext = "AI could not find: \(targetGame)"
                        let suggestions = Array(games.keys.prefix(3))
                        let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: suggestions)
                        let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                        if callBPrompt != "SKIP_CALL_B" {
                            let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                            updatedContext.coolUncleResponse = callBResponse
                            onCommandExecuted("AI could not find: \(targetGame)")
                        }
                    }
                } else {
                    // Not a recommendation strategy - use original not found behavior
                    updatedContext.actionType = "game_not_found"
                    updatedContext.actionContext = "AI could not find: \(targetGame)"
                    let suggestions = Array(games.keys.prefix(3))
                    let notFoundDecision = SearchDecision.gameNotFound(searched: targetGame, suggestions: suggestions)
                    let callBPrompt = strategy.buildCallBPrompt(decision: notFoundDecision, context: context)
                    if callBPrompt != "SKIP_CALL_B" {
                        let callBResponse = try await executeCallB(callBPrompt: callBPrompt, context: updatedContext, apiKey: apiKey)
                        updatedContext.coolUncleResponse = callBResponse
                        onCommandExecuted("AI could not find: \(targetGame)")
                    }
                }
            }
            
        default:
            AppLogger.emit(type: .launchRouting, content: "Decision: Unhandled decision type")
            updatedContext.actionContext = "Unhandled decision"
        }
        
        // Update stored fields
        updatedContext.targetGame = targetGame
        updatedContext.searchTermsUsed = searches

        #if DEBUG
        print("🚀 OPTIMIZED SEARCH: Complete")
        #endif
        
        // Clear optimized search flags
        isUsingOptimizedSearch = false
        currentSearchStrategy = nil
        
        return updatedContext
    }
    
    /// Simple Call B execution for optimized search strategies
    private func executeCallB(callBPrompt: String, context: ThreeCallContext, apiKey: String) async throws -> String {
        // Update status to show AI response generation
        Task { @MainActor in
            uiStateService?.showStatus("Cool Uncle is generating a response...")
        }

        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.8,
            "max_tokens": 300,
            "messages": [
                ["role": "system", "content": getCallB_SystemPrompt()],  // Use base system prompt with no-emoji rule
                ["role": "user", "content": callBPrompt]  // Strategy prompt becomes the user message
            ]
        ]

        let response = try await makeOpenAIRequest(callPhase: "B-Strategy", context: "executeCallB", requestBody: requestBody, apiKey: apiKey)

        guard let content = extractContentFromResponse(response) else {
            throw NSError(domain: "CallB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract Call B response"])
        }

        // Parse JSON response to extract speech (same logic as parseCallB_Response)
        let (speech, _) = parseCallB_Response(content)

        // Hide transient status, add assistant bubble (Consumer UI integration)
        Task { @MainActor in
            uiStateService?.hideStatus()
            chatBubbleService?.addAssistantMessage(speech)
        }

        return speech
    }
    
    // MARK: - Optimized Launch Specific Search
    
    /// Execute optimized launch_specific search with 3 search terms and parallel execution
    private func executeLaunchSpecificSearch(
        context: ThreeCallContext,
        apiKey: String,
        onCommandGenerated: @escaping (String) -> Void,
        onCommandExecuted: @escaping (String) -> Void
    ) async throws -> ThreeCallContext {

        #if DEBUG
        print("🚀 OPTIMIZED LAUNCH_SPECIFIC: Starting new fast path")
        #endif

        // Phase 1: Generate 3 search terms in one LLM call
        #if DEBUG
        print("🚀 Phase 1: Generating 3 search terms")
        #endif
        let searchTermsTask = buildLaunchSpecificSearchTermsPrompt(context: context)

        let requestBody: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0.2,
            "max_tokens": 200,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": getConsolidatedCallA_SystemPrompt()],  // CONSOLIDATED: Enables caching
                ["role": "user", "content": searchTermsTask]
            ]
        ]
        
        let response = try await makeOpenAIRequest(callPhase: "A-SearchTerms", context: "executeLaunchSpecificSearch-phase1", requestBody: requestBody, apiKey: apiKey)
        
        // Log the raw response for console.app
        if let content = extractContentFromResponse(response) {
            AppLogger.aiResponseWithDetail(
                phase: "A-SearchTerms",
                response: "🤖 Raw AI Response: \(content)"
            )
        }
        
        // Parse search terms response
        guard let content = extractContentFromResponse(response),
              let data = content.data(using: .utf8),
              let searchTermsData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let searches = searchTermsData["searches"] as? [String],
              let targetGame = searchTermsData["target_game"] as? String,
              let targetSystem = searchTermsData["system"] as? String?
        else {
            #if DEBUG
            print("❌ OPTIMIZED LAUNCH_SPECIFIC: Failed to parse search terms response")
            #endif
            throw NSError(domain: "LaunchSpecificSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse search terms"])
        }

        #if DEBUG
        print("🚀 Generated search terms: \(searches)")
        print("🚀 Target game: \(targetGame)")
        print("🚀 Target system: \(targetSystem ?? "nil")")
        #endif

        // Phase 2: Execute all searches in parallel
        #if DEBUG
        print("🚀 Search Pattern: EXECUTE (\(searches.count) searches in parallel)")
        #endif

        for (index, searchTerm) in searches.enumerated() {
            let searchCommand = """
            {"jsonrpc":"2.0","id":"","method":"media.search","params":{"query":"\(searchTerm)","systems":["\(targetSystem ?? "")"]}}
            """

            #if DEBUG
            print("🚀 Search \(index + 1): \(searchTerm)")
            #endif

            // Execute search and collect results
            onCommandGenerated(searchCommand)
            // No artificial delay between parallel search dispatches
        }
        
        // Phase 3: Wait for all results and make decision
        // For now, we'll need to handle this differently since the search results 
        // come back asynchronously. We'll mark this as a special case.
        
        var updatedContext = context
        updatedContext.actionType = "launch_specific_optimized"
        updatedContext.actionContext = "Executed optimized search for \(targetGame)"
        updatedContext.targetGame = targetGame
        updatedContext.searchTermsUsed = searches

        #if DEBUG
        print("🚀 OPTIMIZED LAUNCH_SPECIFIC: Phase 1 complete, waiting for search results")
        #endif
        
        return updatedContext
    }
    
    /// Build prompt for generating 3 search terms for a specific game
    private func buildLaunchSpecificSearchTermsPrompt(context: ThreeCallContext) -> String {
        return """
        You are a game search term generator. The user wants to find a specific game.
        
        Generate 3 search terms that will find this game in a ROM collection:
        
        1. **Full name**: The game name as the user said it
        2. **Keyword**: Most distinctive single word from the title
        3. **Abbreviation**: ROM abbreviation or alternate form
        
        Examples:
        - "Mega Man 5" → ["Mega Man 5", "mega", "mm5"]
        - "Street Fighter II" → ["Street Fighter II", "fighter", "sf2"]
        - "Super Mario World" → ["Super Mario World", "mario", "smw"]
        
        You must also identify the target system from the user request.
        
        Return JSON format:
        {
            "searches": ["term1", "term2", "term3"],
            "target_game": "exact game name user wants",
            "system": "SYSTEM_NAME"
        }
        
        Available systems: \(context.availableSystems.joined(separator: ", "))
        
        CRITICAL: Use exact system names from the list above.
        """
    }
    
    /// Build prompt for deciding on exact match from search results
    private func buildLaunchSpecificDecisionPrompt(context: ThreeCallContext, allResults: [Any]) -> String {
        let targetGame = context.targetGame ?? "unknown game"
        
        return """
        You are a game matcher. The user requested: "\(targetGame)"
        
        Here are ALL search results from multiple searches:
        \(allResults)
        
        RULES:
        1. Find EXACTLY "\(targetGame)" (any region/version acceptable)
        2. If found, launch it with exact path
        3. If not found, return game_not_found
        4. NO "close enough" matches - be precise
        
        Examples of exact matches:
        - User wants "Mega Man 5" → "Mega Man 5 (USA)" = MATCH ✅
        - User wants "Mega Man 5" → "Mega Man 4 (USA)" = NO MATCH ❌
        
        Return JSON format:
        {
            "command": {"jsonrpc": "2.0", "id": "", "method": "launch", "params": {"text": "exact_path"}} OR null,
            "action_type": "launch_specific" OR "game_not_found",
            "action_context": "Launching \(targetGame)" OR "\(targetGame) not found"
        }
        """
    }
    
    // MARK: - Helper Functions
    
    /// Extract system name from user message for humor responses
    private func extractSystemFromUserMessage(_ message: String) -> String? {
        let message = message.lowercased()
        
        // Common system name patterns
        let systemPatterns = [
            ("32x", "32X"),
            ("sega32x", "32X"), 
            ("genesis", "Genesis"),
            ("nintendo", "Nintendo"),
            ("nes", "NES"),
            ("snes", "SNES"),
            ("super nintendo", "SNES"),
            ("gameboy", "Game Boy"),
            ("game boy", "Game Boy"),
            ("atari", "Atari"),
            ("amiga", "Amiga"),
            ("arcade", "Arcade"),
            ("neo geo", "Neo Geo"),
            ("neogeo", "Neo Geo"),
            ("psx", "PlayStation"),
            ("playstation", "PlayStation"),
            ("turbografx", "TurboGrafx-16"),
            ("pc engine", "PC Engine")
        ]
        
        for (pattern, systemName) in systemPatterns {
            if message.contains(pattern) {
                return systemName
            }
        }
        
        return nil
    }
    
    /// Generate Cool Uncle humor response when yolo search fails
    private func generateCoolUncleResponseYoloSearchFailed(_ userMessage: String) -> String {
        let systemName = extractSystemFromUserMessage(userMessage) ?? "that system"
        
        let humorous_excuses = [
            "The nintendo ninjas have locked down \(systemName)",
            "My processor's somehow not powerful enough for \(systemName)",
            "The man says it's just too much power to allow \(systemName)",
            "The \(systemName) overlords are blocking me",
            "Corporate won't let me access \(systemName) right now"
        ]
        
        let excuse = humorous_excuses.randomElement() ?? "The nintendo ninjas have locked down \(systemName)"
        
        return "\(excuse)... Or you don't have games for \(systemName) or forgot to re-scan your games on zaparoo."
    }
    
    /// Check if a JSON command is a game launch command
    private func isLaunchCommand(_ jsonCommand: String?) -> Bool {
        guard let command = jsonCommand,
              let data = command.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return false
        }
        return method == "launch"
    }
    
    /// Build action context for Call B based on launch command and original user action
    private func buildActionContextForCallB(originalAction: String?, userMessage: String, launchCommand: String) -> String {
        guard let action = originalAction else { return "Launching game" }
        
        switch action {
        case "recommend", "recommend_alternative": 
            return "This game just launched from AI recommendation - describe why this is a great choice"
        case "launch_specific":
            return "This game just launched from user request - brief acknowledgment only"
        case "random":
            return "This random game just launched - enthusiastic description"
        default:
            return "This game just launched - action was \(action)"
        }
    }
    
    
    /// Check if a JSON command is a search command (media.search)
    private func isSearchCommand(_ jsonCommand: String?) -> Bool {
        guard let command = jsonCommand,
              let data = command.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return false
        }
        return method == "media.search"
    }
    
    /// Check if a JSON command is a random launch command (contains **launch.random:)
    private func isRandomLaunchCommand(_ jsonCommand: String?) -> Bool {
        guard let command = jsonCommand,
              let data = command.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              method == "launch",
              let params = json["params"] as? [String: Any],
              let text = params["text"] as? String else {
            return false
        }
        return text.contains("**launch.random:")
    }
    
    /// Check if a JSON command is an input command (**input.keyboard:)
    private func isInputCommand(_ jsonCommand: String?) -> Bool {
        guard let command = jsonCommand,
              let data = command.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              method == "launch",
              let params = json["params"] as? [String: Any],
              let text = params["text"] as? String else {
            return false
        }
        return text.hasPrefix("**input.")
    }
    
    // MARK: - Command Execution Results
    
    /// Update command execution result (called by the UI layer)
    func updateCommandExecutionResult(_ result: String, actualGameName: String? = nil) {
        if let gameName = actualGameName {
            commandExecutionResult = "\(result) - Actual game: \(gameName)"
        } else {
            commandExecutionResult = result
        }
        AppLogger.openAI("📥 Command execution result updated: \(commandExecutionResult ?? "none")")
    }
    
    /// Handle random game launch with actual game name
    /// This replaces the placeholder response with a proper game-specific response
    /// Note: AI recommendations now use separate action types (recommend/recommend_confirm)
    func handleRandomGameLaunch(
        gameName: String,
        userMessage: String,
        conversationHistory: [ChatMessage],
        apiKey: String,
        isAIRecommendation: Bool = false // Deprecated: only used for true random games now
    ) async {
        // Notify Call C dispatch service of A/B activity
        await CallCDispatchService.shared.notifyABActivity()

        AppLogger.openAI("🎯 Generating specific response for random game: \(gameName)")

        // Build context for the random game response
        let gameHistory = await MainActor.run { UserGameHistoryService.shared.getGameContextSummary() }
        let gamePreferences = await MainActor.run { GamePreferenceService.shared.getPreferenceContextForAI() }

        AppLogger.openAI("📝 Random game context - Game: \(gameName), User message: \(userMessage)")

        // Create snapshot for the random game that actually launched
        // Use CurrentGameService to get launch command if the random game is now current
        let randomGameSnapshot: GameContextSnapshot
        let currentGameName = await MainActor.run { CurrentGameService.shared.currentGameName }
        if currentGameName?.lowercased() == gameName.lowercased() {
            // Use current game service to get complete context including launch command
            randomGameSnapshot = CurrentGameService.shared.createGameContextSnapshot(forUserMessage: userMessage)
        } else {
            // Fallback for cases where random game hasn't updated CurrentGameService yet
            randomGameSnapshot = GameContextSnapshot(
                currentGame: gameName,
                currentSystem: nil,
                forUserMessage: userMessage,
                lastLaunchCommand: nil
            )
        }
        
        // Handle true random game responses (AI recommendations now use separate action types)
        let randomGameContext = ThreeCallContext(
            userMessage: userMessage, // Use original user request like "Play a random PlayStation game"
            conversationHistory: conversationHistory,
            gameHistory: gameHistory,
            gamePreferences: gamePreferences,
            availableSystems: [],
            gameContextSnapshot: randomGameSnapshot,
            jsonCommand: nil,
            actionType: "random", // Only for true random requests now
            actionContext: "Random game launched: \(gameName)"
        )
        
        do {
            // Use execution result format that matches the extraction pattern in buildCallB_SpeechPrompt()
            let executionResult = "Command executed successfully - Actual game: \(gameName)"
            AppLogger.openAI("🐛 RANDOM DEBUG: About to generate Call B with executionResult: '\(executionResult)' and gameName: '\(gameName)'")
            
            let updatedContext = try await executeCallB_SpeechGeneration(
                context: randomGameContext,
                executionResult: executionResult,
                apiKey: apiKey
            )
            
            if let speech = updatedContext.coolUncleResponse {
                coolUncleResponse = speech
                AppLogger.openAI("✅ Generated random game response: \(speech)")
            }
        } catch {
            AppLogger.openAI("❌ Failed to generate random game response: \(error)")
        }
    }
    
    /// Log all system prompts for review on startup
    func logSystemPrompts() {
        AppLogger.standard("📋 === SYSTEM PROMPTS ON STARTUP ===")
        AppLogger.standard("📋 CALL A SYSTEM PROMPT:\n\(getCallA_SystemPrompt())")
        AppLogger.standard("📋 CALL A TASK-SPECIFIC PROMPT:\n\(getTaskSpecificSystemPrompt())")
        AppLogger.standard("📋 CALL B SYSTEM PROMPT:\n\(getCallB_SystemPrompt())")
        AppLogger.standard("📋 CALL C: See SentimentAnalysisService.swift (extracted to separate service)")
        AppLogger.standard("📋 === END SYSTEM PROMPTS ===")
    }
    
    /// Cancel any ongoing processing
    func cancel() {
        // Set cancellation flag (blocks commands at two chokepoints)
        _isCancellationRequested = true

        // Cancel Swift Task (stops OpenAI API calls)
        currentTask?.cancel()

        // Clear pending Call C requests
        // Prevents sentiment analysis on cancelled requests (e.g., "Add to like list" → cancel)
        CallCDispatchService.shared.clearQueue()

        // Clear status message (removes "Classifying request..." etc.)
        Task { @MainActor in
            uiStateService?.hideStatus()
        }

        // Reset UI state
        isLoading = false

        AppLogger.standard("🛑 Cancellation requested - blocking all commands + clearing Call C queue")
    }

    /// Reset cancellation state for new request
    func resetCancellationState() {
        _isCancellationRequested = false
    }

    /// Handle MiSTer disconnection - cancel searches and reset state
    func handleDisconnection() {
        AppLogger.standard("🔌 MiSTer disconnected - cancelling active searches")

        // Cancel ongoing processing
        cancel()

        // Clear any pending search continuations before clearing batch
        // This prevents searches from getting stuck waiting for results
        if let batch = activeSearchBatch {
            Task {
                await searchResultManager.clear(searchIDs: Array(batch.searchIDs))
            }
        }

        // Clear active search batch to prevent stale results
        activeSearchBatch = nil

        AppLogger.standard("✅ Search cleanup complete after disconnection")
    }

    /// Clear all results
    func clearResults() {
        generatedCommand = nil
        commandExecutionResult = nil
        coolUncleResponse = ""
        lastError = nil
    }

    // MARK: - Error Handling

    /// Convert technical errors into user-friendly messages
    private func friendlyErrorMessage(for error: Error) -> String {
        let nsError = error as NSError

        // Network timeout errors
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return "Uh oh, I couldn't reach my brain in the cloud. Try that again or check your internet connection."
        }

        // Network connection errors
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "Looks like you're offline. Check your internet connection and try again."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "I can't reach my brain in the cloud right now. Give it a moment and try again."
            case NSURLErrorNetworkConnectionLost:
                return "Lost connection to my brain. Try that again."
            default:
                return "Network hiccup! Try that again or check your internet connection."
            }
        }

        // Fall back to technical error for unexpected cases
        return error.localizedDescription
    }
}

// MARK: - Error Types

enum OpenAIServiceError: Error, LocalizedError {
    case invalidURL
    case invalidRequest(String)
    case networkError(String)
    case apiError(String)
    case parseError(String)
    case emptyResponse
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OpenAI API URL"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .apiError(let message):
            return "OpenAI API error: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .emptyResponse:
            return "Empty response from OpenAI"
        }
    }
}

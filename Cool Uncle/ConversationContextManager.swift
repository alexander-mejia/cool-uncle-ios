import Foundation

/// Main orchestrator for building optimal conversation context for OpenAI API calls
/// 
/// **Architecture**: Utility class following the established pattern that combines
/// conversation history, game context, and intelligent token management to provide
/// the AI with maximum useful context within API limits.
///
/// **Key Benefits**:
/// - Builds compressed conversation history to save tokens
/// - Integrates game session context from SessionManager command logs
/// - Manages token limits automatically to prevent API failures
/// - Provides realistic context about MiSTer state limitations
/// - Optimizes for Cool Uncle's gaming use case
///
/// **Usage**:
/// ```swift
/// let contextManager = ConversationContextManager()
/// let messages = contextManager.buildOptimalContext(
///     systemPrompt: settings.systemPrompt,
///     userMessage: "Find me a puzzle game",
///     conversationHistory: chatHistory,
///     sessionManager: zaparooService.sessionManager
/// )
/// ```
@MainActor
class ConversationContextManager {
    
    // MARK: - Main Context Building
    
    /// Build optimal context for OpenAI API call - NO TRUNCATION
    func buildOptimalContext(
        systemPrompt: String,
        userMessage: String,
        conversationHistory: [ChatMessage] = [],
        maxTokens: Int = 50000
    ) -> [ChatMessage] {
        
        // 1. Extract persistent user game history context
        let gameContext = UserGameHistoryService.shared.getGameContextSummary()
        
        // 2. Build enhanced system prompt with game context (no conversation history here)
        let enhancedPrompt = buildEnhancedSystemPrompt(
            original: systemPrompt,
            conversationSummary: "", // Don't embed conversation in system prompt
            gameHistory: gameContext,
            maxTokens: maxTokens
        )
        
        // 3. Calculate available tokens for conversation history
        let systemTokens = TokenEstimator.estimate(enhancedPrompt)
        let userTokens = TokenEstimator.estimate(userMessage)
        _ = maxTokens - systemTokens - userTokens - 100 // Reserve 100 tokens buffer
        
        // 4. Include ALL conversation history (no truncation for testing)
        let truncatedHistory = conversationHistory
        
        // 5. Build final message array: [system, ...conversation history..., current user message]
        var messages: [ChatMessage] = []
        messages.append(ChatMessage(role: "system", content: enhancedPrompt))
        messages.append(contentsOf: truncatedHistory)
        messages.append(ChatMessage(role: "user", content: userMessage))
        
        return messages
    }
    
    // MARK: - Conversation History Compression
    
    /// Compress conversation history to token-efficient format
    /// Converts from JSON structure to "Usr: ... Me: ..." format
    private func compressConversationHistory(_ history: [ChatMessage]) -> String {
        if history.isEmpty {
            return ""
        }
        
        let compressed = history.map { message in
            let role = message.role == "user" ? "Usr" : "Me"
            return "\(role): \(message.content)"
        }.joined(separator: "\n")
        
        return compressed
    }
    
    // MARK: - Enhanced System Prompt Building
    
    /// Build enhanced system prompt with conversation and game context
    private func buildEnhancedSystemPrompt(
        original: String,
        conversationSummary: String,
        gameHistory: String,
        maxTokens: Int
    ) -> String {
        
        // Calculate available space for context additions
        let basePromptTokens = TokenEstimator.estimate(original)
        let availableForContext = maxTokens - basePromptTokens - 500 // Reserve 500 for user message
        
        if availableForContext <= 0 {
            // Not enough space for context, return original
            return original
        }
        
        // Build context sections
        var contextSections: [String] = []
        var usedTokens = 0
        
        // Add conversation history if available and fits
        if !conversationSummary.isEmpty {
            let conversationSection = buildConversationSection(conversationSummary)
            let conversationTokens = TokenEstimator.estimate(conversationSection)
            
            if usedTokens + conversationTokens <= availableForContext {
                contextSections.append(conversationSection)
                usedTokens += conversationTokens
            }
        }
        
        // Add game history if available and fits
        if !gameHistory.isEmpty {
            let gameSection = buildGameSection(gameHistory)
            let gameTokens = TokenEstimator.estimate(gameSection)
            
            if usedTokens + gameTokens <= availableForContext {
                contextSections.append(gameSection)
                usedTokens += gameTokens
            } else if contextSections.isEmpty {
                // If we can't fit full game history but have space, truncate it
                let truncatedHistory = TokenEstimator.truncateToFit(gameHistory, maxTokens: availableForContext - 100)
                if !truncatedHistory.isEmpty {
                    contextSections.append(buildGameSection(truncatedHistory))
                }
            }
        }
        
        // Assemble final prompt
        if contextSections.isEmpty {
            return original
        }
        
        return original + "\n\n" + contextSections.joined(separator: "\n\n")
    }
    
    /// Build conversation history section for system prompt
    private func buildConversationSection(_ conversationSummary: String) -> String {
        return """
        CURRENT CONVERSATION:
        (Recent exchange with user - use this context to provide coherent responses)
        \(conversationSummary)
        """
    }
    
    /// Build game history section for system prompt
    private func buildGameSection(_ gameHistory: String) -> String {
        return """
        PERSONAL GAMING CONTEXT:
        (User's persistent gaming history across all sessions and locations)
        \(gameHistory)
        """
    }
    
    // MARK: - Token Management Helpers
    
    /// Get token breakdown for debugging
    func getTokenBreakdown(
        systemPrompt: String,
        userMessage: String,
        conversationHistory: [ChatMessage] = []
    ) -> String {
        
        let messages = buildOptimalContext(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            conversationHistory: conversationHistory
        )
        
        var breakdown = "Context Token Breakdown:\n"
        
        for (index, message) in messages.enumerated() {
            let tokens = TokenEstimator.estimate(message.content)
            let role = message.role.uppercased()
            breakdown += "\(role) (\(index + 1)): \(tokens) tokens\n"
        }
        
        let total = TokenEstimator.estimate(messages)
        breakdown += "TOTAL: \(total) tokens"
        
        return breakdown
    }
    
    /// Check if context fits within specified limits
    func validateContextSize(
        systemPrompt: String,
        userMessage: String,
        conversationHistory: [ChatMessage] = [],
        maxTokens: Int = 3000
    ) -> (fits: Bool, actualTokens: Int, breakdown: String) {
        
        let messages = buildOptimalContext(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            conversationHistory: conversationHistory,
            maxTokens: maxTokens
        )
        
        let actualTokens = TokenEstimator.estimate(messages)
        let fits = actualTokens <= maxTokens
        let breakdown = getTokenBreakdown(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            conversationHistory: conversationHistory
        )
        
        return (fits: fits, actualTokens: actualTokens, breakdown: breakdown)
    }
    
    // MARK: - Smart History Management
    
    /// Intelligently truncate conversation history to fit token budget
    func truncateConversationHistory(
        _ history: [ChatMessage],
        maxTokens: Int
    ) -> [ChatMessage] {
        
        if TokenEstimator.estimate(history) <= maxTokens {
            return history
        }
        
        // Strategy: Keep recent exchanges, prioritize complete user/assistant pairs
        var truncated: [ChatMessage] = []
        var currentTokens = 0
        
        // Process in reverse to prioritize recent messages
        let reversedHistory = Array(history.reversed())
        
        for message in reversedHistory {
            let messageTokens = TokenEstimator.estimate(message.content) + 4 // +4 for structure
            
            if currentTokens + messageTokens <= maxTokens {
                truncated.insert(message, at: 0)
                currentTokens += messageTokens
            } else {
                break
            }
        }
        
        // Ensure we don't start with an assistant message (incomplete exchange)
        while !truncated.isEmpty && truncated.first?.role == "assistant" {
            truncated.removeFirst()
        }
        
        return truncated
    }
    
    /// Get conversation summary for very long histories
    func summarizeOldConversation(_ messages: [ChatMessage]) -> String {
        // Simple summarization - could be enhanced with AI summarization later
        let messageCount = messages.count
        let exchanges = messageCount / 2
        
        // Extract key topics mentioned
        let allContent = messages.map { $0.content }.joined(separator: " ")
        let gameKeywords = extractGameKeywords(from: allContent)
        
        var summary = "Earlier conversation (\(exchanges) exchanges)"
        if !gameKeywords.isEmpty {
            summary += " discussed: \(gameKeywords.joined(separator: ", "))"
        }
        
        return summary
    }
    
    /// Extract game-related keywords from conversation text
    private func extractGameKeywords(from text: String) -> [String] {
        let gameWords = ["game", "play", "launch", "NES", "SNES", "Amiga", "Genesis", "action", "puzzle", "RPG", "platformer", "arcade"]
        let lowercaseText = text.lowercased()
        
        return gameWords.filter { keyword in
            lowercaseText.contains(keyword.lowercased())
        }
    }
}
import Foundation

/// Estimates token usage for OpenAI API calls to manage costs and limits
/// 
/// **Architecture**: Shared utility class following the established pattern
/// of SessionManager and UUIDUtility for common functionality across services.
///
/// **Key Benefits**:
/// - Prevents token limit overruns that cause API failures
/// - Enables smart context truncation to fit within model limits
/// - Provides cost estimation for budget management
/// - Uses industry-standard 4:1 character-to-token ratio for English text
///
/// **Usage**:
/// ```swift
/// let tokenCount = TokenEstimator.estimate("Hello world")
/// let canFit = TokenEstimator.canFitInLimit(messages, limit: 3000)
/// let cost = TokenEstimator.estimateCost(tokenCount, model: "gpt-4o-mini")
/// ```
@MainActor
class TokenEstimator {
    
    // MARK: - Token Estimation
    
    /// Estimate tokens for a single text string
    /// Uses the standard 4:1 character-to-token ratio for English text
    static func estimate(_ text: String) -> Int {
        // Rule of thumb: ~4 characters = 1 token for English
        // Add minimum of 1 token for empty strings
        return max(1, text.count / 4)
    }
    
    /// Estimate tokens for an array of ChatMessage objects
    static func estimate(_ messages: [ChatMessage]) -> Int {
        return messages.reduce(0) { total, message in
            // +4 tokens for role/structure overhead per message
            total + estimate(message.content) + 4
        }
    }
    
    /// Estimate tokens for compressed conversation history format
    static func estimateCompressed(_ conversationText: String) -> Int {
        // Compressed format: "Usr: message\nMe: response\n"
        // Slightly more efficient than full JSON structure
        return estimate(conversationText)
    }
    
    // MARK: - Limit Checking
    
    /// Check if messages fit within token limit
    static func canFitInLimit(_ messages: [ChatMessage], limit: Int = 3000) -> Bool {
        return estimate(messages) <= limit
    }
    
    /// Check if text fits within token limit
    static func canFitInLimit(_ text: String, limit: Int = 3000) -> Bool {
        return estimate(text) <= limit
    }
    
    /// Get available tokens remaining for a given limit
    static func availableTokens(used: Int, limit: Int = 3000) -> Int {
        return max(0, limit - used)
    }
    
    // MARK: - Model-Specific Limits
    
    /// Get context window size for different OpenAI models
    static func contextLimit(for model: String) -> Int {
        switch model {
        case "gpt-4o-mini":
            return 128000 // 128K context window
        case "gpt-4o":
            return 128000 // 128K context window
        case "gpt-4-turbo":
            return 128000 // 128K context window
        case "gpt-3.5-turbo":
            return 16385 // 16K context window
        default:
            return 4000 // Conservative default
        }
    }
    
    /// Get practical working limit (leaves room for response)
    static func workingLimit(for model: String) -> Int {
        let contextLimit = self.contextLimit(for: model)
        // Reserve 1000 tokens for response generation
        return max(1000, contextLimit - 1000)
    }
    
    // MARK: - Cost Estimation
    
    /// Estimate API cost in USD for token usage
    /// Prices as of 2025 - may need updates
    static func estimateCost(_ tokens: Int, model: String) -> Double {
        let costPerToken: Double
        
        switch model {
        case "gpt-4o-mini":
            costPerToken = 0.00000015 // $0.15 per 1M input tokens
        case "gpt-4o":
            costPerToken = 0.0000025  // $2.50 per 1M input tokens
        case "gpt-4-turbo":
            costPerToken = 0.00001    // $10.00 per 1M input tokens
        case "gpt-3.5-turbo":
            costPerToken = 0.0000005  // $0.50 per 1M input tokens
        default:
            costPerToken = 0.00001    // Conservative estimate
        }
        
        return Double(tokens) * costPerToken
    }
    
    // MARK: - Smart Truncation Helpers
    
    /// Truncate text to fit within token limit while preserving word boundaries
    static func truncateToFit(_ text: String, maxTokens: Int) -> String {
        // Guard against invalid maxTokens values
        guard maxTokens > 0 else { return "" }
        
        if estimate(text) <= maxTokens {
            return text
        }
        
        // Binary search for optimal length
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        var left = 0
        var right = words.count
        var bestFit = ""
        
        while left <= right {
            let mid = (left + right) / 2
            let candidate = Array(words[0..<mid]).joined(separator: " ")
            
            if estimate(candidate) <= maxTokens {
                bestFit = candidate
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        
        // Safe fallback with character limit (ensure positive value)
        return bestFit.isEmpty ? String(text.prefix(max(1, maxTokens * 4))) : bestFit
    }
    
    /// Truncate conversation history to fit within token budget
    static func truncateConversation(_ messages: [ChatMessage], maxTokens: Int) -> [ChatMessage] {
        if estimate(messages) <= maxTokens {
            return messages
        }
        
        // Keep recent messages, remove oldest first
        var truncated: [ChatMessage] = []
        var currentTokens = 0
        
        // Process in reverse to prioritize recent messages
        for message in messages.reversed() {
            let messageTokens = estimate(message.content) + 4 // +4 for structure
            
            if currentTokens + messageTokens <= maxTokens {
                truncated.insert(message, at: 0)
                currentTokens += messageTokens
            } else {
                break
            }
        }
        
        return truncated
    }
    
    // MARK: - Debug Helpers
    
    /// Get detailed token breakdown for debugging
    static func debugBreakdown(_ messages: [ChatMessage]) -> String {
        var breakdown = "Token Breakdown:\n"
        var total = 0
        
        for (index, message) in messages.enumerated() {
            let tokens = estimate(message.content) + 4
            total += tokens
            breakdown += "Message \(index + 1) (\(message.role)): \(tokens) tokens\n"
        }
        
        breakdown += "Total: \(total) tokens"
        return breakdown
    }
}
//
//  SentimentAnalysisService.swift
//  Cool Uncle
//
//  Created by Claude on 2025-11-19.
//  Call C: Background sentiment analysis for user game preferences
//
//  ARCHITECTURE:
//  - Completely self-contained service independent of EnhancedOpenAIService
//  - Called asynchronously via CallCDispatchService
//  - Updates GamePreferenceService based on detected sentiment
//  - Own prompts, timeouts, retry logic, and OpenAI request handling
//

import Foundation
import SwiftUI

/// Service for analyzing user sentiment about games and updating preferences
@MainActor
class SentimentAnalysisService: ObservableObject {
    static let shared = SentimentAnalysisService()

    // MARK: - Configuration

    /// Model configuration for Call C (sentiment analysis)
    private let modelConfig = ModelConfig(
        model: "gpt-4o-mini",
        temperature: 0.3,
        maxTokens: 300
    )

    /// Network timeout for sentiment analysis requests
    private let requestTimeoutSeconds: TimeInterval = 60

    /// Maximum retry attempts for network timeouts
    private let maxRetries = 2

    /// Cloudflare proxy configuration
    /// BYOK (Bring Your Own Key) mode: Set to false for direct OpenAI API calls
    /// Set to true only if you're running your own Cloudflare Worker proxy
    private let useCloudflareProxy = false
    private let cloudflareProxyURL = "https://cooluncle-backend.cooluncle.workers.dev/chat"
    private let baseURL = "https://api.openai.com/v1/chat/completions"

    // MARK: - Private Init (Singleton)

    private init() {}

    // MARK: - Public Interface

    /// Execute sentiment analysis for queued request from CallCDispatchService
    func executeSentimentAnalysis(context: CallCContext, apiKey: String) async {
        do {
            let threeCallContext = context.toThreeCallContext()
            _ = try await executeCallC_SentimentAnalysis(context: threeCallContext, apiKey: apiKey)

        } catch {
            AppLogger.standard("❌ Queued Call C failed: \(error)")
        }
    }

    // MARK: - Call C Execution

    /// Execute Call C sentiment analysis
    private func executeCallC_SentimentAnalysis(
        context: ThreeCallContext,
        apiKey: String
    ) async throws -> ThreeCallContext {

        let prompt = buildCallC_SentimentPrompt(context: context)

        // Use model configuration
        AppLogger.openAI("🔧 CALL C: \(modelConfig.description)")

        var requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": getCallC_SystemPrompt()],
                ["role": "user", "content": prompt]
            ]
        ]

        // Apply config
        modelConfig.apply(to: &requestBody, defaults: modelConfig)

        let response = try await makeOpenAIRequest(
            callPhase: "C",
            context: "SentimentAnalysis",
            requestBody: requestBody,
            apiKey: apiKey
        )

        guard let content = extractContentFromResponse(response),
              !content.isEmpty else {
            throw OpenAIServiceError.emptyResponse
        }

        // Parse sentiment analysis response
        let (sentimentAnalysis, preferenceUpdates) = parseCallC_Response(content)

        // Apply preference updates if any were suggested
        if let updates = preferenceUpdates, !updates.isEmpty {
            await processSentimentUpdates(updates)
        }

        var updatedContext = context
        updatedContext.sentimentAnalysis = sentimentAnalysis
        updatedContext.preferenceUpdates = preferenceUpdates

        return updatedContext
    }

    // MARK: - Prompt Generation

    /// Get specialized system prompt for Call C (sentiment analysis)
    /// OPTIMIZED FOR CACHING: All static examples and rules in system prompt
    private func getCallC_SystemPrompt() -> String {
        return """
        You are a sentiment analysis expert for gaming preferences. Analyze if the user expressed sentiment about ONE specific game.

        Your response must be a JSON object:
        {
            "game_classifications": [
                {
                    "game_name": "exact game name provided",
                    "category": "DISLIKED|WANT_TO_PLAY|FAVORITES|null",
                    "confidence": 0-100,
                    "reasoning": "brief explanation"
                }
            ],
            "conversation_insights": "Key patterns for future recommendations"
        }

        ENUM CATEGORIES (use exact strings):
        - "DISLIKED": Clear negative sentiment (hate, boring, don't like, frustrated)
        - "WANT_TO_PLAY": Expressed desire to play - NOW or LATER (want to try, want to play, play later, save for later)
        - "FAVORITES": Strong positive sentiment (love, amazing, best game, awesome)
        - null: Game mentioned but no clear preference expressed

        CRITICAL RULES:
        - You will be given ONE specific game to analyze
        - Only classify that exact game - ignore any other games mentioned
        - Only classify if you're 70%+ confident about the sentiment
        - Use null for ambiguous cases, commands, or questions without sentiment
        - Focus ONLY on the specified game - ignore any other games mentioned

        SENTIMENT PATTERN RECOGNITION:

        POSITIVE (→ FAVORITES):
        - "I love this game" / "Love this" / "Like this game" / "Like this" / "I like this"
        - "This game is awesome" / "This is great" / "This is fun" / "Amazing" / "Enjoying this"
        - "This game rocks" / "Perfect" / "Excellent" / "This is good" / "This is cool"

        NEGATIVE (→ DISLIKED):
        - "I don't like this game" / "Don't like this" / "Hate this" / "I don't like this"
        - "This game sucks" / "This sucks" / "Boring" / "This is boring"
        - "Not good" / "Bad game" / "Terrible" / "Not into this" / "Not really feeling this"

        INTEREST (→ WANT_TO_PLAY):
        - "I want to try this game" / "Want to play this" / "Looks interesting"
        - "I should play this" / "Might be fun"
        - "Wanna play this later" / "Play this another time" / "Save this for later" / "I'll come back to this"
        - "Add this to my playlist" / "Add to playlist" / "Add this to my list" / "Put this on my list"

        NO SENTIMENT (→ null):
        - "How do I play this game?" / "What's this about?" / "Help with controls"
        - "Can you recommend a game?" / "Find me a game" / "Play something else"
        - "What about [different system] games?" / "Try a different game" / "Something new"
        - "Let's quit this game" / "Stop the game" / "Exit this" / "Save and quit"
        - "Pause this" / "Reset the game" / "Load my save" / "Menu please"

        COMPOUND STATEMENTS - Analyze the ENTIRE message:
        - "I don't like this game, can we play something else?" → NEGATIVE (explicit dislike)
        - "This is boring, try something different" → NEGATIVE (boring = negative sentiment)
        - "I wanna play this later, recommend something for now" → INTEREST (explicit future interest)
        - "Can we play something else?" → NULL (pure request, no sentiment about current game)
        - "How about an Atari game instead?" → NULL (preference for different system ≠ dislike of current game)

        CRITICAL CLASSIFICATION RULES:
        1. Explicit sentiment words (love/hate/boring/awesome/sucks) → High confidence classification
        2. LIST CURATION ACTIONS (add to playlist/list/queue) → WANT_TO_PLAY (the act of saving = interest)
        3. Future play intent ("want to try", "play later") → WANT_TO_PLAY
        4. In compound statements, analyze ALL clauses - if ANY part expresses sentiment, classify that sentiment
        5. Pure requests for alternatives WITHOUT sentiment words OR list curation = NULL

        QUICK REFERENCE EXAMPLES:
        "I don't like this game" → DISLIKED (90% confidence)
        "This game is amazing" → FAVORITES (95% confidence)
        "I want to try this game" → WANT_TO_PLAY (80% confidence)
        "Add this to my playlist" → WANT_TO_PLAY (85% confidence - list curation = intent to play)
        "Can you add this to my list" → WANT_TO_PLAY (85% confidence - saving game = future play intent)
        "How do I play this game?" → null (no sentiment expressed)
        "Play a different game" → DISLIKED (85% confidence - implies dislike of current)
        """
    }

    /// Build optimized user prompt for Call C (sentiment analysis)
    /// OPTIMIZED FOR CACHING: Dynamic content at the END to maximize cache hits
    private func buildCallC_SentimentPrompt(context: ThreeCallContext) -> String {

        // Use the immutable snapshot - this is the game that was running when the user spoke
        let targetGame = context.gameContextSnapshot.sentimentTargetGame

        // CACHE-OPTIMIZED STRUCTURE:
        // 1. Static instruction (cacheable)
        // 2. Semi-stable game context (partially cacheable)
        // 3. Dynamic user message at END (not cached, but minimal)
        return """
        TASK: Analyze if the user expressed sentiment about the game specified below.

        Game being discussed: \(targetGame)
        Action taken: \(context.actionType ?? "unknown")

        User statement: "\(context.userMessage)"
        """
    }

    // MARK: - Response Processing

    /// Parse Call C response to extract game classifications
    private func parseCallC_Response(_ content: String) -> (sentimentAnalysis: String?, preferenceUpdates: String?) {
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Extract game classifications
            if let classifications = json["game_classifications"] as? [[String: Any]] {
                var updates: [String] = []

                for classification in classifications {
                    guard let gameName = classification["game_name"] as? String,
                          let confidence = classification["confidence"] as? Int,
                          confidence >= 70 else { continue }

                    if let category = classification["category"] as? String, category != "null" {
                        let reasoning = classification["reasoning"] as? String ?? "Sentiment analysis"
                        updates.append("\(gameName): \(category) (\(confidence)% - \(reasoning))")
                    }
                }

                let insights = json["conversation_insights"] as? String ?? ""
                return (sentimentAnalysis: insights, preferenceUpdates: updates.isEmpty ? nil : updates.joined(separator: "; "))
            }
        }

        // Fallback: treat as plain sentiment analysis
        return (sentimentAnalysis: content.trimmingCharacters(in: .whitespacesAndNewlines), preferenceUpdates: nil)
    }

    /// Process sentiment updates and apply to user preferences
    private func processSentimentUpdates(_ updates: String) async {
        // Parse the structured updates and apply them directly to GamePreferenceService
        let updatePairs = updates.components(separatedBy: "; ")

        for updatePair in updatePairs {
            let parts = updatePair.components(separatedBy: ": ")
            guard parts.count >= 2 else { continue }

            let gameName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let categoryInfo = parts[1]

            // Extract reasoning from "FAVORITES (95% - reasoning)" format
            let reasoning = extractReasoningFromCategoryInfo(categoryInfo)

            // Extract category from "FAVORITES (95% - reasoning)"
            if categoryInfo.contains("FAVORITES") {
                GamePreferenceService.shared.recordGameFromConversation(gameName, category: .favorites, reason: reasoning)
                AppLogger.standard("❤️ Call C: '\(gameName)' → Favorites")
                AppLogger.openAI("❤️ Added '\(gameName)' to favorites: \(reasoning)")
            } else if categoryInfo.contains("DISLIKED") {
                GamePreferenceService.shared.recordGameFromConversation(gameName, category: .disliked, reason: reasoning)
                AppLogger.standard("👎 Call C: '\(gameName)' → Disliked")
                AppLogger.openAI("👎 Added '\(gameName)' to disliked: \(reasoning)")
            } else if categoryInfo.contains("WANT_TO_PLAY") {
                GamePreferenceService.shared.recordGameFromConversation(gameName, category: .wantToPlay, reason: reasoning)
                AppLogger.standard("⭐ Call C: '\(gameName)' → Want to Play")
                AppLogger.openAI("⭐ Added '\(gameName)' to want to play: \(reasoning)")
            }
        }
    }

    /// Extract reasoning from category info string like "FAVORITES (95% - User said they loved it)"
    private func extractReasoningFromCategoryInfo(_ categoryInfo: String) -> String {
        // Look for pattern like "(95% - reasoning)"
        if let dashRange = categoryInfo.range(of: " - "),
           let closeParen = categoryInfo.range(of: ")", range: dashRange.upperBound..<categoryInfo.endIndex) {
            let reasoning = String(categoryInfo[dashRange.upperBound..<closeParen.lowerBound])
            return reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback to generic message if parsing fails
        return "User sentiment detected"
    }

    // MARK: - Network Layer

    /// Make HTTP request to OpenAI API (routes to proxy or direct based on configuration)
    private func makeOpenAIRequest(
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
        guard let url = URL(string: cloudflareProxyURL) else {
            throw OpenAIServiceError.invalidURL
        }

        // Log the request
        let messages = requestBody["messages"] as? [[String: Any]] ?? []
        let lastMessage = messages.last?["content"] as? String ?? ""

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
                    throw OpenAIServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
                }

                // Success! Parse and return
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw OpenAIServiceError.parseError("Invalid JSON response")
                }

                // Log the response
                logResponseForPhase(callPhase, json, requestBody)

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
        guard let url = URL(string: baseURL) else {
            throw OpenAIServiceError.invalidURL
        }

        // Log the request
        let messages = requestBody["messages"] as? [[String: Any]] ?? []
        let lastMessage = messages.last?["content"] as? String ?? ""

        AppLogger.aiRequestWithTruncation(
            phase: callPhase,
            context: context,
            fullPrompt: lastMessage,
            truncateLength: 50
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw OpenAIServiceError.invalidRequest("Failed to encode request body")
        }

        // Retry logic
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
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

                // Log the response
                logResponseForPhase(callPhase, json, requestBody)

                return json
            } catch {
                lastError = error
                let nsError = error as NSError

                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut && attempt < maxRetries {
                    AppLogger.openAI("⚠️ Request timed out (attempt \(attempt + 1)/\(maxRetries + 1)), retrying...")
                    continue
                }

                throw error
            }
        }

        throw lastError ?? OpenAIServiceError.networkError("Request failed after retries")
    }

    // MARK: - Helper Methods

    /// Extract content from OpenAI response
    private func extractContentFromResponse(_ response: [String: Any]) -> String? {
        guard let choices = response["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    /// Normalize call phase for analytics
    private func normalizeCallPhase(_ phase: String) -> String {
        if phase.hasPrefix("C") || phase.contains("Sentiment") {
            return "C"
        }
        return phase
    }

    /// Log response based on phase
    private func logResponseForPhase(_ phase: String, _ json: [String: Any], _ requestBody: [String: Any]) {
        if let content = extractContentFromResponse(json) {
            // Log full response for Call C (sentiment analysis needs complete visibility)
            AppLogger.openAI("🤖 Call C: \(content)")
        }
    }

    // MARK: - Debug Logging

    /// Log Call C system prompt for debugging
    func logSystemPrompt() {
        AppLogger.standard("📋 CALL C SYSTEM PROMPT:\n\(getCallC_SystemPrompt())")
    }
}

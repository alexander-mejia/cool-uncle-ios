import Foundation

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?
    
    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }
}

struct ChatCompletionResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage?
    
    struct Choice: Codable {
        let index: Int
        let message: ChatMessage?
        let delta: Delta?
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case index, message, delta
            case finishReason = "finish_reason"
        }
    }
    
    struct Delta: Codable {
        let role: String?
        let content: String?
    }
    
    struct Usage: Codable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

struct OpenAIError: Codable {
    let error: ErrorDetail
    
    struct ErrorDetail: Codable {
        let message: String
        let type: String
        let code: String?
    }
}

@MainActor
class OpenAIService: ObservableObject {
    @Published var isLoading = false
    @Published var streamingResponse = ""
    @Published var naturalLanguageResponse = ""
    @Published var jsonCommands: [String] = []
    @Published var lastError: String?
    
    private let baseURL = "https://api.openai.com/v1"
    private var streamingTask: URLSessionDataTask?
    
    // Rate limiting to prevent 429 errors  
    private var lastRequestTime: Date = Date()
    private let minimumRequestInterval: TimeInterval = 1.0 // Wait at least 1 second between requests
    
    func sendMessage(
        messages: [ChatMessage],
        apiKey: String,
        model: String = "gpt-4o-mini",
        maxTokens: Int? = 1000,
        temperature: Double = 0.7,
        streaming: Bool = true
    ) async {
        AppLogger.standard("📺 LEGACY OpenAI: sendMessage called with \(messages.count) messages, model: \(model)")
        AppLogger.standard("📺 LEGACY OpenAI: isLoading = \(isLoading) (should be false before new request)")
        
        guard !apiKey.isEmpty else {
            lastError = "API key is required"
            AppLogger.verbose("📺 LEGACY OpenAI: API key is empty!")
            return
        }
        
        AppLogger.verbose("📺 LEGACY OpenAI: API key length: \(apiKey.count)")
        
        // Rate limiting: wait if we're making requests too quickly
        let timeSinceLastRequest = Date().timeIntervalSince(lastRequestTime)
        if timeSinceLastRequest < minimumRequestInterval {
            let waitTime = minimumRequestInterval - timeSinceLastRequest
            AppLogger.verbose("📺 LEGACY Rate limiting: waiting \(String(format: "%.1f", waitTime))s before OpenAI request")
            // TEMPORARILY DISABLED - debugging 429 issue
            // try? await Task.sleep(for: .seconds(waitTime))
        }
        
        lastRequestTime = Date()
        AppLogger.standard("📺 LEGACY OpenAI request starting (time since last: \(String(format: "%.1f", timeSinceLastRequest))s)")
        isLoading = true
        lastError = nil
        
        if streaming {
            streamingResponse = ""
            naturalLanguageResponse = ""
            jsonCommands = []
            await sendStreamingRequest(
                messages: messages,
                apiKey: apiKey,
                model: model,
                maxTokens: maxTokens,
                temperature: temperature
            )
        } else {
            await sendNonStreamingRequest(
                messages: messages,
                apiKey: apiKey,
                model: model,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }
        
        // Parse the complete response after streaming is done
        parseResponseContent()
        
        isLoading = false
    }
    
    private func sendStreamingRequest(
        messages: [ChatMessage],
        apiKey: String,
        model: String,
        maxTokens: Int?,
        temperature: Double
    ) async {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            lastError = "Invalid URL"
            return
        }
        
        let request = createRequest(
            url: url,
            apiKey: apiKey,
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            temperature: temperature,
            streaming: true
        )
        
        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return
            }
            
            AppLogger.verbose("📺 LEGACY OpenAI: HTTP Response Code: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 429 {
                    // Read the error response body to see which rate limit was exceeded
                    var errorBody = ""
                    for try await line in asyncBytes.lines {
                        errorBody += line
                    }
                    
                    if let errorData = errorBody.data(using: .utf8),
                       let errorResponse = try? JSONDecoder().decode(OpenAIError.self, from: errorData) {
                        lastError = "Rate limit exceeded: \(errorResponse.error.message)"
                        AppLogger.standard("📺 LEGACY ❌ OpenAI 429 Error Details:")
                        AppLogger.standard("📺 LEGACY    Type: \(errorResponse.error.type)")
                        AppLogger.standard("📺 LEGACY    Message: \(errorResponse.error.message)")
                        AppLogger.standard("📺 LEGACY    Code: \(errorResponse.error.code ?? "none")")
                    } else {
                        lastError = "Rate limit exceeded (429) - could not parse error details"
                        AppLogger.standard("📺 LEGACY ❌ OpenAI 429 Error - Raw response: \(errorBody)")
                    }
                } else {
                    lastError = "HTTP Error: \(httpResponse.statusCode)"
                    AppLogger.standard("📺 LEGACY ❌ OpenAI HTTP Error: \(httpResponse.statusCode)")
                }
                isLoading = false
                return
            }
            
            for try await line in asyncBytes.lines {
                await processStreamingLine(line)
            }
            
        } catch {
            lastError = "Network error: \(error.localizedDescription)"
            AppLogger.standard("📺 LEGACY ❌ OpenAI streaming request failed: \(error)")
            AppLogger.verbose("📺 LEGACY Full streaming error details: \(error)")
        }
        
        isLoading = false
    }
    
    private func processStreamingLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Skip empty lines and non-data lines
        guard trimmed.hasPrefix("data: ") else { return }
        
        let jsonString = String(trimmed.dropFirst(6)) // Remove "data: "
        
        // Check for end of stream
        if jsonString == "[DONE]" {
            return
        }
        
        guard let data = jsonString.data(using: .utf8) else { return }
        
        do {
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            
            if let choice = response.choices.first,
               let content = choice.delta?.content {
                streamingResponse += content
            }
        } catch {
            #if DEBUG
            print("📺 LEGACY Failed to decode streaming response: \(error)")
            #endif
        }
    }
    
    private func sendNonStreamingRequest(
        messages: [ChatMessage],
        apiKey: String,
        model: String,
        maxTokens: Int?,
        temperature: Double
    ) async {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            lastError = "Invalid URL"
            return
        }
        
        let request = createRequest(
            url: url,
            apiKey: apiKey,
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            temperature: temperature,
            streaming: false
        )
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return
            }
            
            if httpResponse.statusCode == 200 {
                let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                if let content = chatResponse.choices.first?.message?.content {
                    streamingResponse = content
                }
            } else {
                AppLogger.verbose("📺 LEGACY OpenAI: Non-streaming HTTP Response Code: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 429 {
                    // Decode 429 error details from response body
                    if let errorResponse = try? JSONDecoder().decode(OpenAIError.self, from: data) {
                        lastError = "Rate limit exceeded: \(errorResponse.error.message)"
                        AppLogger.standard("📺 LEGACY ❌ OpenAI 429 Error Details (non-streaming):")
                        AppLogger.standard("📺 LEGACY    Type: \(errorResponse.error.type)")
                        AppLogger.standard("📺 LEGACY    Message: \(errorResponse.error.message)")
                        AppLogger.standard("📺 LEGACY    Code: \(errorResponse.error.code ?? "none")")
                    } else {
                        lastError = "Rate limit exceeded (429) - could not parse error details"
                        let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                        AppLogger.standard("📺 LEGACY ❌ OpenAI 429 Error - Raw response: \(errorBody)")
                    }
                } else {
                    let errorResponse = try JSONDecoder().decode(OpenAIError.self, from: data)
                    lastError = errorResponse.error.message
                    AppLogger.standard("📺 LEGACY ❌ OpenAI HTTP Error \(httpResponse.statusCode): \(errorResponse.error.message)")
                }
            }
        } catch {
            lastError = "Request failed: \(error.localizedDescription)"
            AppLogger.standard("📺 LEGACY ❌ OpenAI non-streaming request failed: \(error)")
            AppLogger.verbose("📺 LEGACY Full non-streaming error details: \(error)")
        }
    }
    
    private func createRequest(
        url: URL,
        apiKey: String,
        messages: [ChatMessage],
        model: String,
        maxTokens: Int?,
        temperature: Double,
        streaming: Bool
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody = ChatCompletionRequest(
            model: model,
            messages: messages,
            stream: streaming,
            maxTokens: maxTokens,
            temperature: temperature
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            #if DEBUG
            print("📺 LEGACY Failed to encode request: \(error)")
            #endif
        }
        
        return request
    }
    
    func cancelStreaming() {
        streamingTask?.cancel()
        isLoading = false
    }
    
    func clearResponse() {
        streamingResponse = ""
        naturalLanguageResponse = ""
        jsonCommands = []
        lastError = nil
    }
    
    // Parse the streaming response to separate natural language from JSON commands
    private func parseResponseContent() {
        let content = streamingResponse
        
        var extractedCommands: [String] = []
        var naturalText = content
        
        // Method 1: Find JSON code blocks (```json ... ```)
        let jsonPattern = #"```json\s*([\s\S]*?)\s*```"#
        let regex = try! NSRegularExpression(pattern: jsonPattern, options: [])
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        
        // Extract JSON commands in reverse order to maintain string indices
        for match in matches.reversed() {
            if let jsonRange = Range(match.range(at: 1), in: content) {
                let jsonContent = String(content[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                extractedCommands.insert(jsonContent, at: 0)
            }
            
            // Remove the entire code block from natural language response
            if let fullRange = Range(match.range(at: 0), in: content) {
                let fullMatch = content[fullRange]
                naturalText = naturalText.replacingOccurrences(of: "```json\n\(fullMatch)\n```", with: "")
                naturalText = naturalText.replacingOccurrences(of: "```json\(fullMatch)```", with: "")
                naturalText = naturalText.replacingOccurrences(of: String(fullMatch), with: "")
            }
        }
        
        // Method 2: Check if entire response is raw JSON (no code blocks)
        if extractedCommands.isEmpty {
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidJSON(trimmedContent) {
                // Entire response is JSON command
                extractedCommands.append(trimmedContent)
                naturalText = "" // No natural language if entire response is JSON
                AppLogger.emit(type: .debug, content: "Detected entire response as raw JSON command")
            }
        }
        
        // Clean up natural language response
        naturalLanguageResponse = naturalText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validate and fix JSON commands before sending
        let validatedCommands = extractedCommands.compactMap { command in
            return validateAndFixJSONCommand(command)
        }
        
        jsonCommands = validatedCommands

        // Debug: Show what commands were extracted
        #if DEBUG
        print("📺 LEGACY 🔍 OpenAI: Extracted \(extractedCommands.count) JSON commands from response")
        for (index, command) in extractedCommands.enumerated() {
            print("📺 LEGACY 📋 OpenAI: Command \(index + 1): \(command)")
        }
        #endif
        
        // Auto-send commands to MiSTer (notify via published property)
        if !extractedCommands.isEmpty {
            #if DEBUG
            print("📺 LEGACY 🚀 OpenAI: Auto-sending \(extractedCommands.count) commands to MiSTer")
            #endif
        }
    }
    
    // Helper method to create messages with conversation context
    func createMessages(
        systemPrompt: String, 
        userMessage: String,
        conversationHistory: [ChatMessage] = []
    ) -> [ChatMessage] {
        
        // Use ConversationContextManager for intelligent context building
        let contextManager = ConversationContextManager()
        
        let messages = contextManager.buildOptimalContext(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            conversationHistory: conversationHistory
        )
        
        // Debug: Print context information to app logs
        let validation = contextManager.validateContextSize(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            conversationHistory: conversationHistory
        )
        
        AppLogger.emit(type: .debug, content: "Built context with \(validation.actualTokens) tokens (fits: \(validation.fits))")
        AppLogger.emit(type: .debug, content: "Including \(conversationHistory.count) conversation messages")
        
        // Log persistent game context
        let historyCount = UserGameHistoryService.shared.getHistoryCount()
        if historyCount > 0 {
            AppLogger.emit(type: .debug, content: "Including persistent gaming history (\(historyCount) total commands)")
        }
        
        // COMPREHENSIVE DEBUG: Log the complete message structure being sent to OpenAI
        AppLogger.emit(type: .debug, content: "FULL CONTEXT BEING SENT TO OPENAI:")
        for (index, message) in messages.enumerated() {
            let roleEmoji = message.role == "system" ? "⚙️" : (message.role == "user" ? "👤" : "🤖")
            let truncatedContent = String(message.content.prefix(500)) + (message.content.count > 500 ? "..." : "")
            AppLogger.emit(type: .debug, content: "\(roleEmoji) Message \(index + 1) (\(message.role)): \(truncatedContent)")
        }
        
        // Specifically check if conversation history is being preserved
        let conversationMessages = messages.filter { $0.role != "system" }
        if conversationMessages.count > 1 {
            AppLogger.emit(type: .debug, content: "CONVERSATION CONTEXT: \(conversationMessages.count) messages preserved")
        } else {
            AppLogger.emit(type: .debug, content: "CONVERSATION CONTEXT: Only \(conversationMessages.count) message - possible context loss!")
        }
        
        return messages
    }
    
    // Backward compatibility - simple system + user message
    func createMessages(systemPrompt: String, userMessage: String) -> [ChatMessage] {
        return createMessages(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            conversationHistory: []
        )
    }
    
    // Helper method to validate JSON
    private func isValidJSON(_ string: String) -> Bool {
        // Check if string looks like JSON-RPC command
        guard string.hasPrefix("{") && string.hasSuffix("}") else { return false }
        guard string.contains("\"jsonrpc\"") && string.contains("\"method\"") else { return false }
        
        // Validate it's parseable JSON
        guard let data = string.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return true
        } catch {
            return false
        }
    }
    
    // Validate and fix common JSON command errors
    private func validateAndFixJSONCommand(_ command: String) -> String? {
        guard let data = command.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.emit(type: .debug, content: "Invalid JSON command: \(command)")
            return nil
        }
        
        var fixedJson = json
        
        // Check if method contains command that should be in params.text
        if let method = json["method"] as? String {
            
            // Fix: method contains launch command instead of just "launch"
            // Catch cases like: "launch.random:SNES/*", "launch.search:Genesis/*", "**launch.random:NES/*"
            if method.contains("launch.random:") || method.contains("launch.search:") || method.contains("**launch") || 
               (method.hasPrefix("launch.") && method != "launch") {
                AppLogger.emit(type: .debug, content: "Detected invalid method format: \(method)")
                AppLogger.emit(type: .debug, content: "Fixing method field: \(method) → launch")
                fixedJson["method"] = "launch"
                
                // Move the command to params.text
                if fixedJson["params"] == nil {
                    fixedJson["params"] = [String: Any]()
                }
                
                var params = fixedJson["params"] as? [String: Any] ?? [:]
                
                // Add ** prefix if not present for launch commands
                let commandText = method.hasPrefix("**") ? method : "**\(method)"
                params["text"] = commandText
                fixedJson["params"] = params
                
                AppLogger.emit(type: .debug, content: "Fixed JSON command:")
                AppLogger.emit(type: .debug, content: "   Before: {\"method\": \"\(method)\"}")
                AppLogger.emit(type: .debug, content: "   After: {\"method\": \"launch\", \"params\": {\"text\": \"\(commandText)\"}}")
            }
            
            // Validate required methods
            let validMethods = ["media.search", "launch", "stop", "systems"]
            if !validMethods.contains(method) && !method.hasPrefix("**") {
                AppLogger.emit(type: .debug, content: "Unknown method: \(method)")
            }
        }
        
        // Convert back to JSON string
        do {
            let fixedData = try JSONSerialization.data(withJSONObject: fixedJson, options: [])
            let fixedCommand = String(data: fixedData, encoding: .utf8) ?? command
            
            if fixedCommand != command {
                AppLogger.emit(type: .debug, content: "Fixed JSON command")
            }
            
            return fixedCommand
        } catch {
            AppLogger.emit(type: .debug, content: "Failed to serialize fixed JSON: \(error)")
            return command // Return original if fixing fails
        }
    }
}
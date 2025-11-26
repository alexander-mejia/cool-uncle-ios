import SwiftUI

/// Represents a single chat bubble in the conversation
/// Only 3 role types are allowed: user, assistant, action
struct ChatBubble: Identifiable, Codable {
    let id: UUID
    let role: BubbleRole
    let content: String
    let timestamp: Date
    let isCancelled: Bool  // Special styling for cancelled requests
    let isNetworkError: Bool  // True if this is a network error requiring retry
    let retryContext: RetryContext?  // Context needed to retry the failed request

    enum BubbleRole: String, Codable {
        case user       // User voice/text input (blue, right-aligned)
        case assistant  // Cool Uncle Call B response (grey, left-aligned)
        case action     // "Launched [game]" (green, centered)
    }

    init(role: BubbleRole, content: String, isCancelled: Bool = false, isNetworkError: Bool = false, retryContext: RetryContext? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isCancelled = isCancelled
        self.isNetworkError = isNetworkError
        self.retryContext = retryContext
    }
}

/// Context needed to retry a failed network request
struct RetryContext: Codable {
    let userMessage: String
    let conversationHistory: [ChatMessage]
    let gameContextSnapshot: GameContextSnapshot
}

/// Manages persistent chat bubble history
/// Bubbles added here will appear in the chat ScrollView
@MainActor
class ChatBubbleService: ObservableObject {
    @Published var bubbles: [ChatBubble] = []

    /// Add user message bubble (blue, right-aligned)
    /// Call this when user sends voice or text input
    func addUserMessage(_ text: String) {
        let bubble = ChatBubble(role: .user, content: text)
        bubbles.append(bubble)
        AppLogger.standard("💬 User bubble added: \"\(text)\"")
    }

    /// Add action bubble (green, centered)
    /// Call this when a game is successfully launched
    /// - Parameter gameName: Name of the launched game
    func addActionMessage(_ gameName: String) {
        let bubble = ChatBubble(role: .action, content: "Launched \(gameName)")
        bubbles.append(bubble)
        AppLogger.standard("🎮 Action bubble added: \(gameName)")
    }

    /// Add assistant message bubble (grey, left-aligned)
    /// Call this when Call B completes with Cool Uncle response
    func addAssistantMessage(_ text: String) {
        let bubble = ChatBubble(role: .assistant, content: text)
        bubbles.append(bubble)
        AppLogger.standard("🤖 Assistant bubble added")
    }

    /// Add cancellation message bubble (normal grey, no strikethrough)
    /// Call this when user cancels AI processing by tapping STOP button
    /// Also marks the last user bubble as cancelled (with strikethrough)
    func addCancellationMessage() {
        // Mark the last user bubble as cancelled (adds strikethrough, muted colors)
        if let lastUserIndex = bubbles.lastIndex(where: { $0.role == .user }) {
            let oldBubble = bubbles[lastUserIndex]
            let cancelledBubble = ChatBubble(
                role: oldBubble.role,
                content: oldBubble.content,
                isCancelled: true
            )
            // Replace old bubble with cancelled version (preserves id and timestamp)
            bubbles[lastUserIndex] = ChatBubble(
                role: cancelledBubble.role,
                content: cancelledBubble.content,
                isCancelled: true
            )
        }

        // Add "Request stopped" bubble (NOT cancelled - shows clearly without strikethrough)
        let bubble = ChatBubble(role: .assistant, content: "Request stopped", isCancelled: false)
        bubbles.append(bubble)
        AppLogger.standard("🛑 Cancellation bubble added")
    }

    /// Add network error bubble with retry capability
    /// Call this when a network request fails due to timeout or connection loss
    /// - Parameters:
    ///   - message: Error message to display
    ///   - retryContext: Context needed to retry the request
    func addNetworkErrorMessage(_ message: String, retryContext: RetryContext) {
        let bubble = ChatBubble(
            role: .assistant,
            content: message,
            isCancelled: false,
            isNetworkError: true,
            retryContext: retryContext
        )
        bubbles.append(bubble)
        AppLogger.standard("⚠️ Network error bubble added: \(message)")
    }

    /// Remove a specific bubble (used when retrying after network error)
    func removeBubble(_ bubble: ChatBubble) {
        bubbles.removeAll { $0.id == bubble.id }
        AppLogger.standard("🗑️ Bubble removed: \(bubble.id)")
    }

    /// Clear all chat bubbles
    func clear() {
        bubbles.removeAll()
        AppLogger.standard("🗑️ Chat history cleared")
    }
}

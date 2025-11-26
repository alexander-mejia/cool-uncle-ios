import Foundation

/// Manages JSON-RPC session state and request ID generation for WebSocket connections
/// 
/// **Architecture**: Each ZaparooService connection gets its own SessionManager instance
/// that ensures proper UUID format for all JSON-RPC commands sent to the MiSTer FPGA.
///
/// **Key Benefits**:
/// - Generates proper UUID format required by Zaparoo API (prevents -32600 "Invalid Request" errors)
/// - Eliminates AI UUID hallucination issues by handling IDs at the service level
/// - Provides session-based tracking for debugging and request correlation
/// - Automatically resets on connection/disconnection for clean state management
///
/// **Usage**:
/// ```swift
/// private var sessionManager = SessionManager()
/// 
/// // For each JSON-RPC command:
/// let request = ZaparooRequest(
///     id: sessionManager.generateRequestId(),
///     method: "launch",
///     params: params
/// )
/// ```
@MainActor
class SessionManager: ObservableObject {
    private var requestCounter: Int = 0
    private let sessionId: String
    
    init() {
        // Generate a unique session ID when the manager is created
        self.sessionId = UUID().uuidString.lowercased()
        logSessionEvent(.created)
    }
    
    /// Generate a unique request ID for this session
    /// Each request gets a proper UUID (Zaparoo API requires UUID format)
    func generateRequestId() -> String {
        requestCounter += 1
        let requestId = UUID().uuidString.lowercased()
        AppLogger.verbose("🆔 SessionManager: Generated request ID #\(requestCounter): \(requestId)")
        return requestId
    }
    
    /// Reset the session (new connection)
    func resetSession() {
        requestCounter = 0
        logSessionEvent(.reset)
    }
    
    /// Get the current session ID (for debugging)
    var currentSessionId: String {
        return sessionId
    }
    
    /// Get the current request count (for debugging)
    var currentRequestCount: Int {
        return requestCounter
    }
    
    // MARK: - Centralized Command Logging
    
    /// Log when a command attempt is initiated
    func logCommandAttempt(method: String, params: [String: Any]?, connectionState: ZaparooConnectionState) {
        AppLogger.emit(type: .session, content: "SessionManager: Attempting '\(method)' command")
        AppLogger.emit(type: .session, content: "SessionManager: Connection state: \(connectionState)")
        AppLogger.emit(type: .session, content: "SessionManager: Will be request #\(requestCounter + 1) for session \(sessionId.prefix(8))...")
        
        if let params = params {
            AppLogger.emit(type: .debug, content: "SessionManager: Command params: \(params)")
        }
        
        // Record to persistent user history (independent of session)
        UserGameHistoryService.shared.recordGameCommand(method: method, params: params)
    }
    
    /// Log when a command has been processed and assigned an ID
    func logCommandProcessed(requestId: String, method: String) {
        AppLogger.emit(type: .session, content: "SessionManager: Command processed - Method: \(method), ID: \(requestId)")
    }
    
    /// Log when a command is sent via WebSocket
    func logCommandSent(requestId: String) {
        AppLogger.verbose("🌐 SessionManager: Command sent via WebSocket, ID: \(requestId)")
    }
    
    /// Log the final result of a command
    func logCommandResult(requestId: String, success: Bool, error: String? = nil, response: String? = nil) {
        if success {
            AppLogger.emit(type: .session, content: "SessionManager: Command completed successfully, ID: \(requestId)")
            if let response = response {
                AppLogger.emit(type: .debug, content: "SessionManager: Response: \(response)")
            }
        } else {
            AppLogger.emit(type: .session, content: "SessionManager: Command failed, ID: \(requestId)")
            if let error = error {
                AppLogger.emit(type: .error, content: "SessionManager: Error: \(error)")
            }
        }
        
        // Update the persistent user history with the result
        // Note: This is a best-effort update - we don't have perfect command tracking
        // but we can update the most recent matching command
        updateMostRecentCommandResult(success: success, response: response ?? error)
    }
    
    /// Update the most recent command in persistent history with the result
    private func updateMostRecentCommandResult(success: Bool, response: String?) {
        // This is a simplified approach - in a perfect world we'd track request IDs
        // in the persistent history, but for now we'll update the most recent command
        // that doesn't already have a result
        
        // Note: UserGameHistoryService doesn't currently support updating existing commands
        // This could be enhanced in the future for more precise result tracking
        AppLogger.emit(type: .debug, content: "SessionManager: Command result logged to session (persistent history update not yet implemented)")
    }
    
    /// Log session state changes
    func logSessionEvent(_ event: SessionEvent) {
        switch event {
        case .created:
            AppLogger.emit(type: .session, content: "SessionManager: Created new session with ID: \(sessionId)")
        case .reset:
            AppLogger.emit(type: .session, content: "SessionManager: Reset session \(sessionId.prefix(8))..., counter back to 0")
        case .connectionChanged(let state):
            AppLogger.emit(type: .session, content: "SessionManager: Connection state changed to: \(state)")
        }
    }
    
}

// MARK: - Supporting Types

enum SessionEvent {
    case created
    case reset
    case connectionChanged(ZaparooConnectionState)
}
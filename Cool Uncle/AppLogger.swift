import Foundation
import os.log
import UIKit

/// Centralized logging system for Cool Uncle app
///
/// **Usage**:
/// - `AppLogger.standard()` - Essential user flow logs (always visible)
/// - `AppLogger.verbose()` - Detailed debugging logs (controlled by VERBOSE_LOGGING env var)
///
/// **Xcode Setup**:
/// To enable verbose logging, add environment variable in scheme editor:
/// VERBOSE_LOGGING = 1
class AppLogger {

    /// Controls whether verbose logging is enabled
    private static let isVerboseEnabled: Bool = {
        return ProcessInfo.processInfo.environment["VERBOSE_LOGGING"] == "1"
    }()

    // MARK: - Session Log Buffer (for bug reporting)

    /// In-memory session log buffer for bug reporting (captures last ~10,000 log lines)
    private static var sessionLogBuffer: [String] = []
    private static let maxSessionLogLines = 10000
    private static let sessionLogQueue = DispatchQueue(label: "com.cooluncle.sessionlog", qos: .utility)
    
    // MARK: - Structured Loggers (os.Logger for Console.app)
    
    /// OpenAI service logging separated by request/response flow
    private static let aiRequestLogger = Logger(subsystem: "com.cooluncle.ai", category: "Requests")
    private static let aiResponseLogger = Logger(subsystem: "com.cooluncle.ai", category: "Responses")
    
    /// MiSTer FPGA logging separated by request/response flow  
    private static let misterRequestLogger = Logger(subsystem: "com.cooluncle.mister", category: "Requests")
    private static let misterResponseLogger = Logger(subsystem: "com.cooluncle.mister", category: "Responses")
    
    /// User speech input logging
    private static let userInputLogger = Logger(subsystem: "com.cooluncle.user", category: "SpeechInput")
    
    // MARK: - Unified Logging Types
    
    /// All supported log types with their specific routing behavior
    enum LogType {
        case aiRequest(phase: String, context: String)
        case aiResponse(phase: String)
        case aiRawResponse(phase: String)
        case userInput
        case misterCommand(method: String)
        case misterResponse
        case connection
        case session
        case tokenWarning(phase: String, count: Int)
        case gameHistory
        case preferenceUpdate
        case websocketDetail
        case keepAlive
        case launchRouting
        case debug
        case performance
        case storage
        case error
        case standard
    }
    
    /// Truncation behavior for different logging destinations
    enum TruncationMode {
        case none                    // Full content always
        case smart(normal: Int)      // Truncate to N chars in normal mode
        case methodOnly             // Show only method/type name
        case hidden                 // Don't show unless verbose
    }
    
    // MARK: - Session Log Buffer Helpers

    /// Add log entry to session buffer (thread-safe, works in ALL build configurations)
    private static func addToSessionLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"

        sessionLogQueue.async {
            sessionLogBuffer.append(logEntry)
            if sessionLogBuffer.count > maxSessionLogLines {
                sessionLogBuffer.removeFirst()
            }
        }
    }

    // MARK: - Central Logging Router

    /// Central logging emission method that routes logs to appropriate destinations based on matrix rules
    static func emit(
        type: LogType,
        content: String,
        fullContent: String? = nil  // Optional full version if different from content
    ) {
        let isVerbose = isVerboseEnabled
        let actualContent = fullContent ?? content

        // CRITICAL: Add all logs to session buffer for bug reporting (works in RELEASE builds)
        addToSessionLog(actualContent)
        
        switch type {
        case .aiRequest(let phase, let context):
            let charCount = actualContent.count
            
            // Xcode: Truncated in normal (50 chars), full in verbose
            #if DEBUG
            if isVerbose {
                print("🤖 Call \(phase) [\(context)]: '\(actualContent)' [\(charCount) chars]")
            } else {
                let truncated = String(actualContent.prefix(50))
                print("🤖 Call \(phase) [\(context)]: '\(truncated)...' [\(charCount) chars]")
            }
            #endif
            
            // Console.app: Always full (use .notice for persistence)
            aiRequestLogger.notice("🤖 Call \(phase, privacy: .public) [\(context, privacy: .public)]: '\(actualContent, privacy: .public)' [\(charCount, privacy: .public) chars]")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("AI Request Call \(phase) [\(context)]: \(actualContent)")
            }
            
        case .aiResponse(let phase):
            // Xcode: Truncated in normal (200 chars), full in verbose
            #if DEBUG
            if isVerbose {
                print("✅ Call \(phase): \(actualContent)")
            } else {
                let truncated = actualContent.count > 200 ? String(actualContent.prefix(200)) + "..." : actualContent
                print("✅ Call \(phase): \(truncated)")
            }
            #endif
            
            // Console.app: Always full (use .notice for persistence)
            aiResponseLogger.notice("✅ Call \(phase, privacy: .public): \(actualContent, privacy: .public)")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("AI Response Call \(phase): \(actualContent)")
            }
            
        case .aiRawResponse(let phase):
            // Xcode: Hidden in normal, truncated in verbose (100 chars)
            #if DEBUG
            if isVerbose {
                let truncated = actualContent.count > 100 ? String(actualContent.prefix(100)) + "..." : actualContent
                print("🤖 Raw AI Response \(phase): \(truncated)")
            }
            #endif
            
            // Console.app: Always full (use .notice for persistence)
            aiResponseLogger.notice("🤖 Raw AI Response \(phase, privacy: .public): \(actualContent, privacy: .public)")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("AI Raw Response Call \(phase): \(actualContent)")
            }
            
        case .userInput:
            // Xcode: Always full
            #if DEBUG
            print("🗣️ User: \(actualContent)")
            #endif
            
            // Console.app: Always full (use .notice for persistence)
            userInputLogger.notice("🗣️ User: \(actualContent, privacy: .public)")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("User Input: \(actualContent)")
            }
            
        case .misterCommand(let method):
            // Xcode: Method only in normal, full JSON in verbose
            #if DEBUG
            if isVerbose {
                print("🎮→ MiSTer: \(actualContent)")
            } else {
                print("🎮→ MiSTer: \(method)")
            }
            #endif
            
            // Console.app: Always full (use .notice for persistence)
            misterRequestLogger.notice("🎮→ MiSTer: \(actualContent, privacy: .public)")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("MiSTer Command: \(actualContent)")
            }
            
        case .misterResponse:
            // Xcode: Summary in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("📨 MiSTer: \(actualContent)")
            } else {
                // Extract game name for summary if possible
                let summary = extractGameNameForSummary(from: actualContent)
                print("📨 MiSTer: \(summary)")
            }
            #endif
            
            // Console.app: Always full (use .notice for persistence)
            misterResponseLogger.notice("📨 MiSTer: \(actualContent, privacy: .public)")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("MiSTer Response: \(actualContent)")
            }
            
        case .connection:
            // Xcode: Always full
            #if DEBUG
            print("🔌 \(actualContent)")
            #endif
            
            // Console.app: Always full
            misterRequestLogger.notice("🔌 \(actualContent, privacy: .public)")
            
            // Debug file: Always full
            if isVerbose {
                writeToDebugFile("Connection: \(actualContent)")
            }
            
        case .session:
            // Xcode: Always full
            #if DEBUG
            print("🔄 \(actualContent)")
            #endif
            
            // Console.app: Always full
            userInputLogger.notice("🔄 \(actualContent, privacy: .public)")
            
            // Debug file: Always full
            if isVerbose {
                writeToDebugFile("Session: \(actualContent)")
            }
            
        case .tokenWarning(let phase, let count):
            // Xcode: Always full (important warnings)
            #if DEBUG
            print("⚠️ Call \(phase) token usage: \(count) tokens \(actualContent)")
            #endif
            
            // Console.app: Always full
            aiResponseLogger.notice("⚠️ Call \(phase, privacy: .public) token usage: \(count, privacy: .public) tokens \(actualContent, privacy: .public)")
            
            // Debug file: Always full
            if isVerbose {
                writeToDebugFile("Token Warning Call \(phase): \(count) tokens - \(actualContent)")
            }
            
        case .gameHistory:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("💾 \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (not needed for ABC Inspector)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Game History: \(actualContent)")
            }
            
        case .preferenceUpdate:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("⭐ \(actualContent)")
            }
            #endif
            
            // Console.app: Always full (sentiment analysis results)
            aiResponseLogger.notice("⭐ \(actualContent, privacy: .public)")
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Preference Update: \(actualContent)")
            }
            
        case .websocketDetail:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("🌐 \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (low-level details)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("WebSocket Detail: \(actualContent)")
            }
            
        case .keepAlive:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("💓 \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (heartbeat noise)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Keep-Alive: \(actualContent)")
            }
            
        case .launchRouting:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("🚀 \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (internal flow)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Launch Routing: \(actualContent)")
            }
            
        case .debug:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("🔧 \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (generic debug)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Debug: \(actualContent)")
            }
            
        case .performance:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("⚡ \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (performance metrics)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Performance: \(actualContent)")
            }
            
        case .storage:
            // Xcode: Hidden in normal, full in verbose
            #if DEBUG
            if isVerbose {
                print("💽 \(actualContent)")
            }
            #endif
            
            // Console.app: Hidden (storage operations)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Storage: \(actualContent)")
            }
            
        case .error:
            // Xcode: Always full (never truncate errors)
            #if DEBUG
            print("❌ \(actualContent)")
            #endif
            
            // Console.app: Always full
            aiResponseLogger.notice("❌ \(actualContent, privacy: .public)")
            
            // Debug file: Always full
            if isVerbose {
                writeToDebugFile("Error: \(actualContent)")
            }
            
        case .standard:
            // Xcode: Always full
            #if DEBUG
            print("ℹ️ \(actualContent)")
            #endif
            
            // Console.app: Hidden (app lifecycle)
            
            // Debug file: Full when verbose
            if isVerbose {
                writeToDebugFile("Standard: \(actualContent)")
            }
        }
    }
    
    /// Helper method to extract game name for MiSTer response summary
    private static func extractGameNameForSummary(from response: String) -> String {
        // Try to extract meaningful summary from MiSTer response
        if response.contains("Game launched:") {
            return response
        } else if response.contains("media.started") {
            return "Game started"
        } else if response.contains("error") {
            return "Error response"
        } else {
            return "Response received"
        }
    }
    
    /// Helper method to extract method name from MiSTer request message
    private static func extractMethodFromMessage(_ message: String) -> String {
        // Try to extract method from JSON-RPC message
        if message.contains("launch") {
            return "launch"
        } else if message.contains("media.search") {
            return "media.search"
        } else if message.contains("stop") {
            return "stop"
        } else if message.contains("systems") {
            return "systems"
        } else if message.contains("tokens.history") {
            return "tokens.history"
        } else {
            return "unknown"
        }
    }
    
    // MARK: - Standard Logging (Always On)

    /// Log essential user flow information - always visible
    /// CRITICAL: Now sends to Console.app in ALL builds (RELEASE + DEBUG) for bug reporting
    static func standard(_ message: String) {
        #if DEBUG
        print(message)
        #endif

        // Send to Console.app in ALL builds (RELEASE + DEBUG) so TestFlight logs are preserved
        userInputLogger.notice("\(message, privacy: .public)")

        // Add to session log buffer for bug reporting
        addToSessionLog(message)
    }
    
    /// Log connection events
    static func connection(_ message: String) {
        emit(type: .connection, content: message)
    }
    
    /// Log user voice input - full text sent to both Xcode console and Console.app
    static func userInput(_ message: String) {
        emit(type: .userInput, content: message)
    }
    
    /// Log AI natural language responses (clean, readable)
    static func aiResponse(_ message: String) {
        // Extract phase from context if possible, default to "Response"
        emit(type: .aiResponse(phase: "Response"), content: message)
    }
    
    /// Log AI responses with three-tier logging (Xcode potentially truncated, Console.app full, debug file full)
    static func aiResponseWithDetail(
        phase: String,
        response: String,
        showFullInConsole: Bool = true,
        xcodeTruncateLength: Int = 200
    ) {
        emit(type: .aiResponse(phase: phase), content: response)
    }
    
    /// Log JSON commands being sent to MiSTer
    static func commandSent(_ command: String, method: String) {
        emit(type: .misterCommand(method: method), content: command)
    }
    
    /// Log MiSTer FPGA requests (commands going OUT)
    static func misterRequest(_ message: String) {
        // Extract method from message if possible
        let method = extractMethodFromMessage(message)
        emit(type: .misterCommand(method: method), content: message)
    }
    
    /// Log responses from MiSTer
    static func misterResponse(_ message: String) {
        emit(type: .misterResponse, content: message)
    }
    
    /// Log UserGameHistory updates
    static func gameHistory(_ message: String) {
        emit(type: .gameHistory, content: message)
    }
    
    /// Log keep-alive timer status
    static func keepAlive(_ message: String) {
        emit(type: .keepAlive, content: message)
    }
    
    // MARK: - Verbose Logging (Debug Only)
    
    /// Log detailed debugging information - only when VERBOSE_LOGGING=1
    static func verbose(_ message: String) {
        emit(type: .debug, content: message)
    }
    
    /// Log performance metrics
    static func performance(_ message: String) {
        emit(type: .performance, content: message)
    }
    
    /// Log SessionManager operations
    static func session(_ message: String) {
        emit(type: .session, content: message)
    }
    
    /// Log OpenAI service details (AI workflow operations - A/B/C calls)
    /// Routes to Console.app for ABC Inspector visibility
    static func openAI(_ message: String) {
        // 🔧 = debug/verbose logs - Xcode + debug file only (NOT Console.app)
        let isDebugLog = message.hasPrefix("🔧")

        if isDebugLog {
            // Debug logs: Xcode when verbose, always in debug file
            if isVerboseEnabled {
                #if DEBUG
                print(message)
                #endif
                writeToDebugFile("OpenAI Debug: \(message)")
            }
        } else {
            // Workflow logs: Route to Console.app based on emoji
            if message.hasPrefix("🎯") || message.hasPrefix("🤖") {
                // Request logs (🎯 CALL A/B or 🤖 Call C)
                aiRequestLogger.notice("\(message, privacy: .public)")
            } else if message.hasPrefix("✅") {
                // Response logs (✅ CALL A/B/C)
                aiResponseLogger.notice("\(message, privacy: .public)")
            } else {
                // Other AI workflow logs (⏭️, 🎲, etc.)
                aiRequestLogger.notice("\(message, privacy: .public)")
            }

            // Also print to Xcode console
            #if DEBUG
            print(message)
            #endif

            // Debug file when verbose
            if isVerboseEnabled {
                writeToDebugFile("OpenAI Workflow: \(message)")
            }
        }
    }

    /// Extract phase identifier from log message for categorization
    private static func extractPhaseFromMessage(_ message: String) -> String {
        if message.contains("CALL A") { return "A" }
        if message.contains("CALL B") { return "B" }
        if message.contains("Call C") { return "C" }
        return "Workflow"
    }
    
    /// Log WebSocket detailed operations
    static func websocket(_ message: String) {
        emit(type: .websocketDetail, content: message)
    }
    
    /// Log Keychain/UserDefaults operations
    static func storage(_ message: String) {
        emit(type: .storage, content: message)
    }
    
    // MARK: - File Logging
    
    /// Write debug messages to file for full viewing
    private static func writeToDebugFile(_ message: String) {
        guard isVerboseEnabled else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFileURL = documentsPath.appendingPathComponent("cool_uncle_debug.log")
        
        let timestamp = DateFormatter().string(from: Date())
        let logEntry = "\(timestamp): \(message)\n"
        
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                // Append to existing file
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                // Create new file
                try? data.write(to: logFileURL)
            }
        }
    }
    
    /// Get the debug log file path for viewing
    static func getDebugLogPath() -> String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFileURL = documentsPath.appendingPathComponent("cool_uncle_debug.log")
        return logFileURL.path
    }
    
    // MARK: - ABC Tracing Methods
    
    
    /// Log OpenAI API requests with three-tier logging (Xcode truncated, Console.app full, debug file full)
    static func aiRequestWithTruncation(
        phase: String,
        context: String,
        fullPrompt: String,
        truncateLength: Int = 50
    ) {
        emit(type: .aiRequest(phase: phase, context: context), content: fullPrompt)
    }
    
    /// Log OpenAI API responses (all A/B/C responses coming IN) - Use existing aiResponse method
    
    
    /// Log MiSTer FPGA responses (responses coming IN) - Use existing misterResponse method
    
    
    /// Log token usage warnings when exceeding thresholds
    static func tokenWarning(_ count: Int, phase: String) {
        if count > 3000 {
            emit(type: .tokenWarning(phase: phase, count: count), content: "(exceeds 3000 threshold)")
        }
    }
    
    // MARK: - Utility Methods
    
    /// Check if verbose logging is enabled
    static var isVerbose: Bool {
        return isVerboseEnabled
    }
    
    /// Log the current logging configuration on app start
    static func logConfiguration() {
        standard("🚀 Cool Uncle starting up")

        // Log device and app metadata for bug reporting
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model

        standard("📱 App: Cool Uncle v\(appVersion) (build \(buildNumber))")
        standard("📱 iOS: \(iosVersion) on \(deviceModel)")

        if isVerboseEnabled {
            verbose("Verbose logging enabled via VERBOSE_LOGGING environment variable")
            verbose("📄 Full debug log file: \(getDebugLogPath())")
        } else {
            standard("ℹ️  Standard logging mode (set VERBOSE_LOGGING=1 in Xcode for detailed logs)")
        }
    }

    // MARK: - Session Log Retrieval (for bug reporting)

    /// Get the complete session log for bug reporting
    /// Returns last ~10,000 log lines captured during this session
    /// Thread-safe, works in ALL build configurations (DEBUG + RELEASE)
    static func getSessionLog() -> String {
        return sessionLogQueue.sync {
            return sessionLogBuffer.joined(separator: "\n")
        }
    }

    /// Clear the session log buffer (e.g., after successful bug report submission)
    static func clearSessionLog() {
        sessionLogQueue.async {
            sessionLogBuffer.removeAll()
        }
    }
}

// MARK: - Xcode Environment Variable Setup Instructions

/*
 To enable verbose logging in Xcode:
 
 1. Select your scheme in Xcode (next to the run/stop buttons)
 2. Choose "Edit Scheme..."
 3. Select "Run" in the left sidebar
 4. Click the "Arguments" tab
 5. In "Environment Variables" section, click "+"
 6. Add: Name = "VERBOSE_LOGGING", Value = "1"
 7. Click "Close"
 
 Now when you run the app, you'll see detailed verbose logs.
 Remove or set to "0" to return to standard logging.
 */
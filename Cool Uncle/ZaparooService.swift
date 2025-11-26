import Foundation
import Network

// MARK: - Models
struct ZaparooRequest: Codable {
    let jsonrpc: String = "2.0"
    let id: String
    let method: String
    let params: [String: Any]?
    
    init(id: String = UUID().uuidString, method: String, params: [String: Any]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        
        if let paramsData = try container.decodeIfPresent(AnyCodable.self, forKey: .params) {
            params = paramsData.value as? [String: Any]
        } else {
            params = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        
        if let params = params {
            try container.encode(AnyCodable(params), forKey: .params)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

struct ZaparooResponse: Codable {
    let jsonrpc: String
    let id: String?
    let result: [String: Any]?
    let error: ZaparooError?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        
        if let resultData = try container.decodeIfPresent(AnyCodable.self, forKey: .result) {
            result = resultData.value as? [String: Any]
        } else {
            result = nil
        }
        
        error = try container.decodeIfPresent(ZaparooError.self, forKey: .error)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        
        if let result = result {
            try container.encode(AnyCodable(result), forKey: .result)
        }
        
        try container.encodeIfPresent(error, forKey: .error)
    }
    
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }
}

struct ZaparooError: Codable {
    let code: Int
    let message: String
    let data: [String: Any]?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        
        if let data = try container.decodeIfPresent(AnyCodable.self, forKey: .data) {
            self.data = data.value as? [String: Any]
        } else {
            self.data = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        
        if let data = data {
            try container.encode(AnyCodable(data), forKey: .data)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }
}

// Helper for encoding/decoding Any values
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

// MARK: - Connection States
enum ZaparooConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
    
    static func == (lhs: ZaparooConnectionState, rhs: ZaparooConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

// MARK: - ZaparooService
@MainActor
class ZaparooService: NSObject, ObservableObject {
    @Published var connectionState: ZaparooConnectionState = .disconnected
    @Published var lastResponse: String = ""
    @Published var lastError: String = ""
    @Published var lastLaunchedGameName: String? = nil  // Track actual game launched
    @Published var lastLaunchedGameSystem: String? = nil  // Track system of currently running game
    @Published var availableSystems: [String] = []  // Available MiSTer systems from API
    @Published var isIndexing: Bool = false  // Track media indexing status
    
    private var lastRandomSystem: String? = nil  // Track last random system for auto-retry
    
    // Debouncing for duplicate notifications
    private var lastNotificationContent: String? = nil
    private var lastNotificationTime: Date? = nil
    private let notificationDebounceInterval: TimeInterval = 0.25  // 250ms
    
    // ScanTime-gated launch session tracking
    private var lastProcessedScanTime: String? = nil
    private var mediaStartedProcessedForCurrentLaunch = false
    
    // Launch command caching debouncing (per-game basis)
    private var lastNotificationTimes: [String: Date] = [:]  // Track cache times per game
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pendingRequests: [String: ((Result<ZaparooResponse, Error>) -> Void)] = [:]
    private var _sessionManager = SessionManager()
    private var keepAliveTimer: Timer?
    // Battery optimization: 20s interval (industry standard) reduces radio wake-ups by 50%
    // while maintaining reliable connection health. Network proxies typically timeout at 30-120s.
    // Research: https://websockets.readthedocs.io/en/stable/topics/keepalive.html
    private let keepAliveInterval: TimeInterval = 20 // Send WebSocket ping every 20 seconds
    private var reconnectTimer: Timer?
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3
    private var cachedCommands: [(command: String, completion: (Result<ZaparooResponse, Error>) -> Void)] = []
    private var isActivelyReconnecting: Bool = false
    private var isIntentionalDisconnect: Bool = false // Track if disconnect was user-initiated
    private weak var settings: AppSettings? // Reference to get IP address for reconnection
    
    init(settings: AppSettings? = nil) {
        super.init()
        self.settings = settings
        setupURLSession()
    }
    
    // MARK: - Public Access
    
    /// Access to SessionManager for context building
    var sessionManager: SessionManager {
        return _sessionManager
    }
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        // Disable timeouts entirely for persistent WebSocket connections
        // WebSocket keep-alive (ping/pong) handles connection health
        config.timeoutIntervalForRequest = 0 // 0 = no timeout
        config.timeoutIntervalForResource = 0 // 0 = no timeout
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    func connect(to ipAddress: String, port: Int = 7497) {
        guard connectionState != .connecting && connectionState != .connected else { return }

        connectionState = .connecting
        lastError = ""
        isIntentionalDisconnect = false // Reset flag when connecting

        // Clean up any existing connection
        disconnect()
        
        let urlString = "ws://\(ipAddress):\(port)/api/v0.1"
        guard let url = URL(string: urlString) else {
            connectionState = .error("Invalid IP address format")
            return
        }
        
        // Validate WebSocket URL scheme
        guard url.scheme == "ws" || url.scheme == "wss" else {
            connectionState = .error("Invalid WebSocket URL scheme: \(url.scheme ?? "none")")
            return
        }
        
        AppLogger.connection("Attempting to connect to: \(url.absoluteString) (attempt \(reconnectAttempts + 1))")
        AppLogger.verbose("WebSocket URL scheme verified: \(url.scheme ?? "none")")
        
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        // Start listening for messages
        receiveMessage()
        
        // Add connection timeout - use shorter timeout for reconnection attempts
        let timeoutInterval: TimeInterval = reconnectAttempts > 0 ? 4.0 : 15.0
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval) {
            if self.connectionState == .connecting {
                if self.reconnectAttempts > 0 {
                    AppLogger.verbose("Reconnection attempt \(self.reconnectAttempts) timed out after \(timeoutInterval)s")
                    self.attemptReconnection() // Try next attempt
                } else {
                    AppLogger.connection("Initial connection timed out after \(timeoutInterval)s")
                    let errorMessage = "Connection timeout - check if Zaparoo Core is running on MiSTer"
                    AppLogger.emit(type: .debug, content: "🔧 ERROR SOURCE: ZaparooService connection timeout - \(errorMessage)")
                    self.connectionState = .error(errorMessage)
                    self.attemptReconnection()
                }
            }
        }
    }
    
    func disconnect() {
        isIntentionalDisconnect = true // Mark as intentional disconnect
        stopHeartbeat()
        stopReconnection()
        clearCachedCommands(withError: "Connection manually disconnected")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        pendingRequests.removeAll()
        _sessionManager.resetSession()
        reconnectAttempts = 0
        isActivelyReconnecting = false
        lastError = "" // Clear error message on intentional disconnect
        connectionState = .disconnected
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            DispatchQueue.main.async {
                self?.handleReceivedMessage(result)
                // Continue receiving messages
                self?.receiveMessage()
            }
        }
    }
    
    private func handleReceivedMessage(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                handleJSONResponse(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    handleJSONResponse(text)
                }
            @unknown default:
                break
            }
        case .failure(let error):
            AppLogger.verbose("WebSocket receive error: \(error.localizedDescription)")

            // Check if this is a "Socket is not connected" error from clean disconnect
            let nsError = error as NSError
            let isCleanDisconnect = nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 // ENOTCONN
                || error.localizedDescription.contains("Socket is not connected")

            if isCleanDisconnect {
                // This is expected after we called disconnect() - don't set error state or lastError
                AppLogger.verbose("Expected receive error after disconnect - ignoring")
                // Don't change connectionState - it's already .disconnected from disconnect()
                return
            }

            // Only set lastError for unexpected errors
            lastError = "WebSocket error: \(error.localizedDescription)"

            // Don't break the connection for minor receive errors
            // Continue receiving to keep idle timer active
            if connectionState == .connected {
                AppLogger.verbose("Continuing receive loop despite error")
                receiveMessage() // Keep the receive loop alive
            } else {
                AppLogger.emit(type: .debug, content: "🔧 ERROR SOURCE: ZaparooService WebSocket receive error - \(lastError)")
                connectionState = .error(lastError)
            }
        }
    }
    
    private func handleJSONResponse(_ jsonString: String) {
        lastResponse = jsonString
        
        // Parse JSON-RPC response
        guard let data = jsonString.data(using: .utf8) else { return }
        
        // First check for tokens.added notification (launch confirmation)
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           jsonObject["id"] == nil,
           let method = jsonObject["method"] as? String,
           method == "tokens.added",
           let params = jsonObject["params"] as? [String: Any],
           let scanTime = params["scanTime"] as? String {

            AppLogger.verbose("🚀 Launch confirmed with scanTime: \(scanTime)")

            // Reset media.started processing for new launch session
            lastProcessedScanTime = scanTime
            mediaStartedProcessedForCurrentLaunch = false
            AppLogger.verbose("🚀 New launch session started - ready to process first media.started")
            return
        }

        // Check for media.indexing notification (database scanning status)
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           jsonObject["id"] == nil,
           let method = jsonObject["method"] as? String,
           method == "media.indexing",
           let params = jsonObject["params"] as? [String: Any],
           let indexing = params["indexing"] as? Bool {

            let totalFiles = params["totalFiles"] as? Int ?? 0
            let wasIndexing = isIndexing
            isIndexing = indexing

            if indexing {
                AppLogger.standard("📚 Media indexing started - scanning database...")
            } else if wasIndexing && !indexing {
                AppLogger.standard("✅ Media indexing complete - \(totalFiles) files indexed")
                NotificationCenter.default.post(name: Notification.Name("MediaIndexingCompleted"), object: totalFiles)
            }

            return
        }

        // Then check if this is a media.started notification (no id field)
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           jsonObject["id"] == nil,
           let method = jsonObject["method"] as? String,
           method == "media.started",
           let params = jsonObject["params"] as? [String: Any],
           let mediaName = params["mediaName"] as? String {
            
            // ScanTime gating: Only process first media.started per launch session
            if mediaStartedProcessedForCurrentLaunch {
                AppLogger.verbose("🔇 Ignoring duplicate media.started for current launch session: \(mediaName)")
                return
            }
            
            // Mark this launch session as processed
            mediaStartedProcessedForCurrentLaunch = true
            AppLogger.verbose("📺 Processing first media.started for launch session: \(mediaName)")
            
            // Extract system information and media path
            let systemId = params["systemId"] as? String ?? "Unknown"
            let systemName = params["systemName"] as? String ?? systemId
            let mediaPath = params["mediaPath"] as? String
            
            // Debouncing: Check if this is a duplicate notification within 250ms
            let now = Date()
            let notificationKey = "media.started:\(mediaName)"
            
            if let lastTime = lastNotificationTime,
               let lastContent = lastNotificationContent,
               lastContent == notificationKey,
               now.timeIntervalSince(lastTime) < notificationDebounceInterval {
                AppLogger.verbose("🔇 Debounced duplicate notification: \(mediaName) (within \(Int(notificationDebounceInterval * 1000))ms)")
                return
            }
            
            // Update debouncing state
            lastNotificationContent = notificationKey
            lastNotificationTime = now
            
            AppLogger.misterResponse("Notification: media.started - Game: \(mediaName) on \(systemName)")
            AppLogger.emit(type: .debug, content: "⏱️ TIMING: MEDIA_STARTED_RECEIVED at \(Date().timeIntervalSince1970) for game: \(mediaName)")
            
            // Check if this is a non-game system boot (mister-boot, etc.)
            let normalizedMediaName = mediaName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedSystemId = systemId.lowercased()
            let normalizedSystemName = systemName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nonGameBootPrefixes = ["mister-boot", "system-boot"]
            let nonGameExactMatches: Set<String> = ["mister-boot", "system-boot"]
            let hasUsableMediaPath = !(mediaPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let isMenuSystem = normalizedSystemId == "menu" ||
                normalizedSystemName.contains("menu") ||
                normalizedSystemName.contains("mister")

            let isBootPrefix = nonGameBootPrefixes.contains { prefix in
                normalizedMediaName.hasPrefix(prefix + " ") || normalizedMediaName == prefix
            }
            let isKnownNonGameName = nonGameExactMatches.contains(normalizedMediaName)
            let isLikelyLauncher = isMenuSystem || !hasUsableMediaPath

            if (isBootPrefix || isKnownNonGameName) && isLikelyLauncher {
                AppLogger.gameHistory("🚫 Non-game detected: \(mediaName) - auto-retrying random launch")
                
                // Auto-retry the last random command without involving the LLM
                if let system = lastRandomSystem {
                    AppLogger.gameHistory("🔄 Auto-retrying random launch for system: \(system)")
                    let retryCommand = """
                    {
                      "jsonrpc": "2.0",
                      "id": "",
                      "method": "launch",
                      "params": {
                        "text": "**launch.random:\(system)/*"
                      }
                    }
                    """
                    
                    // Send retry command automatically
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.sendJSONCommand(retryCommand) { result in
                            switch result {
                            case .success:
                                AppLogger.gameHistory("✅ Auto-retry random launch sent successfully")
                            case .failure(let error):
                                AppLogger.gameHistory("❌ Auto-retry random launch failed: \(error)")
                            }
                        }
                    }
                }
                return
            }
            
            // This is a real game - process normally
            lastLaunchedGameName = mediaName
            lastLaunchedGameSystem = systemName
            AppLogger.gameHistory("🎮 Media started notification: \(mediaName) on \(systemName)")
            
            // Construct cached launch command from mediaPath
            // Use time-based debouncing: only cache the first valid mediaPath for each game
            // Ignore subsequent paths for the same game within 2 seconds (handles multiple filesystem notifications)
            var cachedLaunchCommand: String? = nil
            if let mediaPath = mediaPath {
                let launchCacheKey = "launch_cache:\(mediaName)"
                let shouldCache: Bool
                
                if let lastCacheTime = lastNotificationTimes[launchCacheKey] {
                    let timeSinceLastCache = now.timeIntervalSince(lastCacheTime)
                    shouldCache = timeSinceLastCache >= 2.0  // 2 second debounce for launch commands
                    if !shouldCache {
                        AppLogger.gameHistory("🚫 Skipping duplicate launch command for '\(mediaName)' (cached \(String(format: "%.1f", timeSinceLastCache))s ago)")
                    }
                } else {
                    shouldCache = true // First time seeing this game
                }
                
                if shouldCache {
                    cachedLaunchCommand = """
                    {
                      "jsonrpc": "2.0",
                      "id": "",
                      "method": "launch",
                      "params": {
                        "text": "**launch:\(mediaPath)"
                      }
                    }
                    """
                    AppLogger.gameHistory("🔗 Cached launch command: **launch:\(mediaPath)")
                    
                    // Update the game preference with the launch command
                    GamePreferenceService.shared.updateLaunchCommand(mediaName, launchCommand: cachedLaunchCommand!)
                    
                    // Update the cache timestamp for this game
                    lastNotificationTimes[launchCacheKey] = now
                }
            }
            
            // Record the actual game that was launched
            UserGameHistoryService.shared.recordGameCommand(
                method: "launch",
                params: ["text": mediaPath ?? mediaName, "actualGame": mediaName],
                success: true,
                response: "Game launched: \(mediaName)"
            )

            // Build launch command for this game (always create it, regardless of cache)
            let launchCommandForHistory: String?
            if let mediaPath = mediaPath {
                launchCommandForHistory = """
                {
                  "jsonrpc": "2.0",
                  "id": "",
                  "method": "launch",
                  "params": {
                    "text": "**launch:\(mediaPath)"
                  }
                }
                """
            } else {
                launchCommandForHistory = nil
            }

            // Add game to played history in GamePreferenceService with launch command
            // Use Task to avoid blocking WebSocket thread (GamePreferenceService is @MainActor)
            Task { @MainActor in
                GamePreferenceService.shared.recordGameLaunch(mediaName, system: systemName, launchCommand: launchCommandForHistory)
            }

            // Notify any observers about the actual game launch with both name and launch command
            var userInfo: [String: Any] = ["gameName": mediaName, "systemName": systemName]
            if let command = cachedLaunchCommand {
                userInfo["launchCommand"] = command
            }
            if let mediaPath = mediaPath {
                userInfo["mediaPath"] = mediaPath
            }
            
            NotificationCenter.default.post(
                name: Notification.Name("GameActuallyLaunched"),
                object: nil,
                userInfo: userInfo
            )
            return
        }
        
        do {
            let response = try JSONDecoder().decode(ZaparooResponse.self, from: data)
            
            // Log the response with ID and result/error
            if let requestId = response.id {
                if let error = response.error {
                    AppLogger.misterResponse("Response ID: \(requestId) - Error \(error.code): \(error.message)")
                    lastError = "Zaparoo Error \(error.code): \(error.message)"
                } else if let result = response.result {
                    // Convert result to a readable string
                    let resultString: String
                    if let jsonData = try? JSONSerialization.data(withJSONObject: result),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        resultString = jsonString
                    } else {
                        resultString = String(describing: result)
                    }
                    AppLogger.verbose("📨 Response ID: \(requestId) - Result: \(resultString)")
                } else {
                    AppLogger.verbose("📨 Response ID: \(requestId) - Empty result")
                }
            }
            
            // Handle response for pending request
            if let requestId = response.id,
               let completion = pendingRequests.removeValue(forKey: requestId) {
                completion(.success(response))
            }
            
        } catch {
            AppLogger.misterResponse("Failed to parse response: \(error.localizedDescription)")
            AppLogger.verbose("Raw response: \(jsonString)")
            lastError = "Failed to parse response: \(error.localizedDescription)"
        }
    }
    
    
    func sendJSONCommand(_ jsonString: String, completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        // If we're actively reconnecting or not connected, cache the command
        if connectionState != .connected && isActivelyReconnecting {
            AppLogger.verbose("Caching command during reconnection: \(jsonString)")
            cachedCommands.append((command: jsonString, completion: completion))
            return
        } else if connectionState != .connected {
            // Not connected and not actively reconnecting - fail immediately
            _sessionManager.logCommandResult(requestId: "unknown", success: false, error: "Not connected to MiSTer")
            completion(.failure(NSError(domain: "ZaparooService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not connected to MiSTer"])))
            return
        }
        
        guard let data = jsonString.data(using: .utf8) else {
            _sessionManager.logCommandResult(requestId: "unknown", success: false, error: "Failed to convert JSON to data")
            completion(.failure(NSError(domain: "ZaparooService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])))
            return
        }
        
        do {
            // Parse the JSON to extract method and params, but ignore any existing ID
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let method = jsonObject["method"] as? String {
                
                let params = jsonObject["params"] as? [String: Any]
                
                // Log the command being sent with ABC Tracing format
                logMiSTerCommand(method: method, params: params)
                
                // Log command attempt with SessionManager (verbose)
                AppLogger.session("Attempting '\(method)' command")
                _sessionManager.logCommandAttempt(method: method, params: params, connectionState: connectionState)
                
                // Create a new request with our managed ID
                let requestId = _sessionManager.generateRequestId()
                let request = ZaparooRequest(
                    id: requestId,
                    method: method,
                    params: params
                )
                
                _sessionManager.logCommandProcessed(requestId: requestId, method: method)
                sendRequest(request) { result in
                    switch result {
                    case .success(let response):
                        self._sessionManager.logCommandResult(requestId: requestId, success: true, response: self.lastResponse)
                        // Log MiSTer response with ABC Tracing format
                        self.logMiSTerResponse(response)
                    case .failure(let error):
                        self._sessionManager.logCommandResult(requestId: requestId, success: false, error: error.localizedDescription)
                        // Log MiSTer error with ABC Tracing format
                        AppLogger.misterResponse("❌ MiSTer error: \(error.localizedDescription)")
                    }
                    completion(result)
                }
            } else {
                _sessionManager.logCommandResult(requestId: "unknown", success: false, error: "Invalid JSON structure - missing method")
                completion(.failure(NSError(domain: "ZaparooService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure"])))
            }
        } catch {
            _sessionManager.logCommandResult(requestId: "unknown", success: false, error: "Failed to parse JSON: \(error)")
            completion(.failure(error))
        }
    }
    
    
    private func sendRequest(_ request: ZaparooRequest, completion: @escaping (Result<ZaparooResponse, Error>) -> Void) {
        guard connectionState == .connected else {
            _sessionManager.logCommandResult(requestId: request.id, success: false, error: "Not connected to MiSTer (state: \(connectionState))")
            completion(.failure(NSError(domain: "ZaparooService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not connected to MiSTer"])))
            return
        }
        
        do {
            let data = try JSONEncoder().encode(request)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                _sessionManager.logCommandResult(requestId: request.id, success: false, error: "Failed to encode request to JSON string")
                completion(.failure(NSError(domain: "ZaparooService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])))
                return
            }
            
            // Store completion handler for response
            pendingRequests[request.id] = completion
            
            // Log via SessionManager
            _sessionManager.logCommandSent(requestId: request.id)
            
            // Send WebSocket message
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { [weak self] error in
                if let error = error {
                    DispatchQueue.main.async {
                        self?._sessionManager.logCommandResult(requestId: request.id, success: false, error: "WebSocket send failed: \(error.localizedDescription)")
                        self?.pendingRequests.removeValue(forKey: request.id)
                        completion(.failure(error))
                    }
                }
                // Note: Success logging happens in sendJSONCommand when response is received
            }
            
        } catch {
            _sessionManager.logCommandResult(requestId: request.id, success: false, error: "Failed to encode request: \(error)")
            completion(.failure(error))
        }
    }
    
    // MARK: - Convenience Methods
    func searchMedia(query: String, systems: [String] = [], preserveId: String? = nil, completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        var params: [String: Any] = ["query": query]
        if !systems.isEmpty {
            params["systems"] = systems
        }

        // Use provided ID if available, otherwise generate new one (backwards compatible)
        let requestId = preserveId ?? sessionManager.generateRequestId()

        #if DEBUG
        if let preserveId = preserveId {
            print("🔗 ZaparooService: Preserving original search ID: \(preserveId)")
        } else {
            print("🆕 ZaparooService: Generated new request ID: \(requestId)")
        }
        #endif

        let request = ZaparooRequest(id: requestId, method: "media.search", params: params)
        sendRequest(request, completion: completion)
    }
    
    func launchGame(text: String, completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        // Launch game with specified text parameter
        AppLogger.standard("🚀 ZaparooService.launchGame() ENTRY: text=\"\(text)\"")
        
        // Clear last launched game name when starting a new launch
        if text.contains("launch.random:") {
            lastLaunchedGameName = nil
            
            // Extract and store the system for potential auto-retry
            lastRandomSystem = extractSystemFromRandomCommand(text)
            AppLogger.gameHistory("🎲 Random game launch initiated for system: \(lastRandomSystem ?? "unknown"), waiting for actual game...")
        }

        // Reset launch-session gating so the next media.started is accepted even if tokens.added
        // is not sent by MiSTer for this launch. This prevents the second random run from being
        // ignored due to a stale previous session state.
        mediaStartedProcessedForCurrentLaunch = false
        lastProcessedScanTime = nil
        lastNotificationContent = nil
        lastNotificationTime = nil
        
        let requestId = sessionManager.generateRequestId()
        let request = ZaparooRequest(id: requestId, method: "launch", params: ["text": text])
        AppLogger.standard("🚀 ZaparooService.launchGame() REQUEST: Generated request ID \(requestId)")
        
        // Debug: show exactly what we're about to send
        if let jsonData = try? JSONEncoder().encode(request),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            AppLogger.standard("🚀 ZaparooService.launchGame() JSON: \(jsonString)")
        }
        
        AppLogger.standard("🚀 ZaparooService.launchGame() SENDING: About to call sendRequest()")
        sendRequest(request) { result in
            AppLogger.standard("🚀 ZaparooService.launchGame() RESPONSE: Received response from sendRequest()")
            completion(result)
        }
    }
    
    func stopCurrentGame(completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        let request = ZaparooRequest(id: sessionManager.generateRequestId(), method: "stop", params: nil)
        sendRequest(request, completion: completion)
    }
    
    func sendKeyboardInput(keys: String, completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        let request = ZaparooRequest(id: sessionManager.generateRequestId(), method: "launch", params: ["text": "**input.keyboard:\(keys)"])
        sendRequest(request, completion: completion)
    }
    
    func getTokenHistory(completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        let request = ZaparooRequest(id: sessionManager.generateRequestId(), method: "tokens.history", params: nil)
        sendRequest(request, completion: completion)
    }
    
    func getSystems(completion: @escaping (Result<ZaparooResponse, Error>) -> Void = { _ in }) {
        let request = ZaparooRequest(id: sessionManager.generateRequestId(), method: "systems", params: nil)
        sendRequest(request, completion: completion)
    }
    
    // MARK: - System Query
    
    private func queryAvailableSystems() {
        AppLogger.connection("Querying available systems from MiSTer...")
        
        getSystems { [weak self] result in
            switch result {
            case .success(let response):
                if let systemsArray = response.result?["systems"] as? [[String: Any]] {
                    // Extract the "id" field from each system object - this is what we use in commands
                    let systemIds = systemsArray.compactMap { systemDict in
                        systemDict["id"] as? String
                    }.sorted()
                    
                    self?.availableSystems = systemIds
                    AppLogger.connection("Available systems loaded: \(systemIds.joined(separator: ", "))")
                    
                    // Notify observers that systems have been updated
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: Notification.Name("SystemsUpdated"),
                            object: nil,
                            userInfo: ["systems": systemIds]
                        )
                    }
                } else {
                    AppLogger.connection("Systems query succeeded but unexpected format")
                    AppLogger.verbose("Systems response: \(response)")
                    // Use fallback system names if format is unexpected
                    self?.availableSystems = self?.getFallbackSystems() ?? []
                }
                
            case .failure(let error):
                AppLogger.connection("Failed to query systems: \(error.localizedDescription)")
                // Use fallback system names if query fails
                self?.availableSystems = self?.getFallbackSystems() ?? []
            }
        }
    }
    
    private func getFallbackSystems() -> [String] {
        // Fallback system names in case the API call fails - use actual MiSTer system IDs
        return [
            "Amiga", "Arcade", "Atari2600", "C64", "GBA", "Gameboy", "Genesis", 
            "MasterSystem", "MegaCD", "NES", "NeoGeo", "PSX", "Sega32X", "SNES", "TurboGrafx16"
        ].sorted()
    }
    
    // MARK: - Keep-Alive Management
    
    private func sendKeepAlive() {
        guard connectionState == .connected else {
            AppLogger.verbose("Skipping keep-alive - not connected")
            return
        }
        
        guard let webSocketTask = webSocketTask else {
            AppLogger.keepAlive("No WebSocket task available for ping")
            return
        }
        
        AppLogger.keepAlive("Sending WebSocket ping")
        webSocketTask.sendPing { [weak self] error in
            if let error = error {
                AppLogger.keepAlive("Ping failed: \(error.localizedDescription)")
                // Ping failure indicates connection issues - trigger reconnection
                DispatchQueue.main.async {
                    self?.attemptReconnection()
                }
            } else {
                AppLogger.keepAlive("Ping successful")
            }
        }
    }
    
    // MARK: - WebSocket Heartbeat Management
    
    private func startHeartbeat() {
        stopHeartbeat() // Ensure no duplicate timers
        
        AppLogger.keepAlive("Started timer (WebSocket ping every \(keepAliveInterval)s)")
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sendKeepAlive()
            }
        }
    }
    
    private func stopHeartbeat() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        AppLogger.keepAlive("Stopped timer")
    }
    
    
    // MARK: - Automatic Reconnection
    
    private func attemptReconnection() {
        guard let settings = settings else {
            AppLogger.emit(type: .connection, content: "⚠️ ZaparooService: No settings reference for reconnection")
            return
        }
        
        let ipAddress = settings.misterIPAddress
        guard !ipAddress.isEmpty else {
            AppLogger.emit(type: .connection, content: "⚠️ ZaparooService: No IP address in settings for reconnection")
            return
        }
        
        guard reconnectAttempts < maxReconnectAttempts else {
            AppLogger.emit(type: .connection, content: "❌ ZaparooService: Max reconnection attempts (\(maxReconnectAttempts)) reached")
            clearCachedCommands(withError: "Connection failed after \(maxReconnectAttempts) attempts")
            connectionState = .error("Connection failed after \(maxReconnectAttempts) attempts")
            isActivelyReconnecting = false
            return
        }
        
        isActivelyReconnecting = true // Mark as actively reconnecting
        reconnectAttempts += 1
        let delay: TimeInterval = Double(reconnectAttempts) * 2.0 // Exponential backoff: 2s, 4s, 6s
        
        AppLogger.emit(type: .connection, content: "🔄 ZaparooService: Attempting reconnection in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                AppLogger.emit(type: .connection, content: "🔄 ZaparooService: Executing reconnection attempt...")
                self.connect(to: ipAddress)
            }
        }
    }
    
    private func stopReconnection() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        AppLogger.emit(type: .connection, content: "🛑 ZaparooService: Stopped reconnection timer")
    }
    
    private func resetReconnectionState() {
        reconnectAttempts = 0
        stopReconnection()
        isActivelyReconnecting = false
    }
    
    // MARK: - Command Caching
    
    private func retryCachedCommands() {
        guard !cachedCommands.isEmpty else { return }
        
        AppLogger.emit(type: .connection, content: "🔄 ZaparooService: Retrying \(cachedCommands.count) cached commands after reconnection")
        
        let commandsToRetry = cachedCommands
        cachedCommands.removeAll() // Clear cache before retrying
        
        for (index, cachedCommand) in commandsToRetry.enumerated() {
            AppLogger.emit(type: .debug, content: "ZaparooService: Retrying cached command \(index + 1)/\(commandsToRetry.count)")
            sendJSONCommand(cachedCommand.command, completion: cachedCommand.completion)
        }
    }
    
    private func clearCachedCommands(withError error: String) {
        guard !cachedCommands.isEmpty else { return }
        
        AppLogger.emit(type: .connection, content: "❌ ZaparooService: Clearing \(cachedCommands.count) cached commands due to: \(error)")
        
        let commandsToFail = cachedCommands
        cachedCommands.removeAll()
        
        for cachedCommand in commandsToFail {
            cachedCommand.completion(.failure(NSError(domain: "ZaparooService", code: -3, userInfo: [NSLocalizedDescriptionKey: error])))
        }
    }
    
    /// Clear cached commands when user navigates away (e.g., back to connection view)
    func clearPendingCommands() {
        if !cachedCommands.isEmpty {
            AppLogger.emit(type: .connection, content: "🗑️ ZaparooService: Clearing \(cachedCommands.count) cached commands - user navigated away")
            clearCachedCommands(withError: "Connection lost and user navigated away")
        }
        isActivelyReconnecting = false
    }
    
    
    // MARK: - ABC Tracing Logging
    
    /// Log MiSTer command with ABC Tracing format
    private func logMiSTerCommand(method: String, params: [String: Any]?) {
        var logMessage = "🎮 → MiSTer: \(method)"
        
        // Add relevant params based on method
        switch method {
        case "launch", "media.search":
            if let text = params?["text"] as? String {
                let preview = String(text.prefix(50))
                logMessage += " {\"text\":\"\(preview)\"}"
            }
        case "tokens.history":
            if let system = params?["system"] as? String {
                logMessage += " {\"system\":\"\(system)\"}"
            }
        case "systems":
            logMessage += " {}" // No params for systems query
        default:
            if let params = params, !params.isEmpty {
                // Show first param for unknown methods
                let firstKey = params.keys.first!
                let firstValue = params[firstKey]!
                logMessage += " {\"\(firstKey)\":\"\(firstValue)\"}"
            }
        }
        
        AppLogger.misterRequest(logMessage)
    }
    
    /// Log MiSTer response with ABC Tracing format
    private func logMiSTerResponse(_ response: ZaparooResponse) {
        if let result = response.result {
            var logMessage = "✅ MiSTer: "
            
            // Handle different result types
            if let type = result["type"] as? String {
                logMessage += "\(type)"
                if let description = result["description"] as? String {
                    logMessage += " → '\(description)'"
                }
            } else if let systems = result["systems"] as? [[String: Any]] {
                logMessage += "systems found: \(systems.count)"
            } else if let tokens = result["tokens"] as? [[String: Any]] {
                logMessage += "tokens found: \(tokens.count)"
            } else {
                logMessage += "success"
            }
            
            AppLogger.misterResponse(logMessage)
            
        } else if let error = response.error {
            AppLogger.misterResponse("❌ MiSTer error: \(error.message)")
        }
    }
    
    // MARK: - Random Command Helpers
    
    /// Extract system name from random launch command
    private func extractSystemFromRandomCommand(_ command: String) -> String? {
        // Pattern: **launch.random:SYSTEM/*
        if let range = command.range(of: "launch.random:") {
            let afterPrefix = String(command[range.upperBound...])
            if let slashRange = afterPrefix.range(of: "/") {
                let systemName = String(afterPrefix[..<slashRange.lowerBound])
                return systemName.isEmpty ? nil : systemName
            }
        }
        return nil
    }
}

// MARK: - URLSessionWebSocketDelegate
extension ZaparooService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            AppLogger.connection("WebSocket connection opened successfully")
            self.connectionState = .connected
            self.lastError = ""
            self.resetReconnectionState() // Reset reconnection attempts on successful connection
            self.startHeartbeat() // Start ping/pong heartbeat
            self.retryCachedCommands() // Retry any cached commands after successful reconnection
            
            // Query available systems on successful connection
            self.queryAvailableSystems()
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.stopHeartbeat() // Stop ping/pong heartbeat
            AppLogger.emit(type: .connection, content: "🔌 WebSocket connection closed (code: \(closeCode.rawValue))")

            // Only attempt reconnection if:
            // 1. We were previously connected
            // 2. We have settings with an IP address
            // 3. This was NOT an intentional disconnect
            if self.connectionState == .connected &&
               self.settings?.misterIPAddress.isEmpty == false &&
               !self.isIntentionalDisconnect {
                AppLogger.emit(type: .connection, content: "🔄 ZaparooService: Connection lost unexpectedly, attempting reconnection...")
                self.connectionState = .connecting
                self.attemptReconnection()
            } else {
                if self.isIntentionalDisconnect {
                    AppLogger.emit(type: .connection, content: "🛑 ZaparooService: Intentional disconnect - no reconnection attempt")
                }
                self.connectionState = .disconnected
            }

            // Clear session timer when connection is lost (unknown game state)
            CurrentGameService.shared.clearSessionTimer()

            self.pendingRequests.removeAll()
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.stopHeartbeat() // Stop heartbeat on connection error
                self.lastError = error.localizedDescription
                
                // Check if this is a timeout error and attempt reconnection
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    AppLogger.emit(type: .connection, content: "⏱️ ZaparooService: Connection timed out, attempting reconnection...")
                    self.connectionState = .connecting
                    self.attemptReconnection()
                } else {
                    self.connectionState = .error(self.lastError)
                    // Clear session timer when connection error occurs (unknown game state)
                    CurrentGameService.shared.clearSessionTimer()
                }
            }
        }
    }
}

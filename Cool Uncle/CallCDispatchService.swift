//
//  CallCDispatchService.swift
//  Cool Uncle
//
//  Created by Claude on 9/22/25.
//  Universal Call C queuing and dispatch system
//

import Foundation
import SwiftUI

/// Context needed for Call C sentiment analysis
struct CallCContext {
    let gameContextSnapshot: GameContextSnapshot
    let userMessage: String
    let conversationHistory: [ChatMessage]
    let actionType: String?
    let timestamp: Date

    /// Convert to ThreeCallContext for existing Call C logic
    func toThreeCallContext() -> ThreeCallContext {
        var context = ThreeCallContext(
            userMessage: userMessage,
            conversationHistory: conversationHistory,
            gameHistory: "", // Not needed for Call C
            gamePreferences: "", // Not needed for Call C
            availableSystems: [], // Not needed for Call C
            gameContextSnapshot: gameContextSnapshot
        )
        // CRITICAL: Preserve actionType from queued context
        context.actionType = actionType
        return context
    }
}

/// Universal Call C dispatch service that monitors A/B activity and queues Call C requests
@MainActor
class CallCDispatchService: ObservableObject {
    static let shared = CallCDispatchService()

    // MARK: - Private Properties
    private var callQueue: [CallCContext] = []
    private var lastABActivity: Date?
    private var dispatchTimer: Timer?
    private var isProcessingQueue = false

    // MARK: - Delegate
    weak var sentimentDelegate: SentimentAnalysisService?
    weak var openAIService: EnhancedOpenAIService?
    private var apiKey: String?

    // MARK: - Constants
    private let AB_DELAY_SECONDS: Double = 5.0  // Wait 5 seconds after A/B activity
    private let CONSECUTIVE_DELAY_SECONDS: Double = 1.0  // Wait 1 second between consecutive C calls

    private init() {}

    // MARK: - Public Interface

    /// Queue a Call C request from user speech completion
    func queueCallC(context: CallCContext) {
        callQueue.append(context)
        AppLogger.standard("🔄 Call C queued: \(context.userMessage) (queue size: \(callQueue.count))")

        // Start processing if not already running
        if !isProcessingQueue {
            processQueue()
        }
    }

    /// Notify that Call A or Call B activity occurred - resets the 5-second timer
    func notifyABActivity() {
        lastABActivity = Date()
        AppLogger.standard("🔔 A/B activity detected - resetting Call C timer")

        // Cancel existing timer and restart processing
        dispatchTimer?.invalidate()
        if !callQueue.isEmpty {
            processQueue()
        }
    }

    /// Set the sentiment analysis service delegate for Call C execution
    func setDelegate(_ delegate: SentimentAnalysisService, apiKey: String) {
        self.sentimentDelegate = delegate
        self.apiKey = apiKey
    }

    /// Set the OpenAI service reference for cancellation checking
    func setOpenAIService(_ service: EnhancedOpenAIService) {
        self.openAIService = service
    }

    /// Clear the Call C queue when user cancels request
    func clearQueue() {
        let queueSize = callQueue.count
        callQueue.removeAll()
        dispatchTimer?.invalidate()
        dispatchTimer = nil
        isProcessingQueue = false

        if queueSize > 0 {
            AppLogger.standard("🛑 Call C queue cleared: \(queueSize) pending requests cancelled")
        }
    }

    // MARK: - Private Queue Processing

    private func processQueue() {
        guard !callQueue.isEmpty else {
            isProcessingQueue = false
            return
        }

        isProcessingQueue = true

        if let lastAB = lastABActivity {
            // We have A/B activity - use normal timing logic
            let timeSinceLastAB = Date().timeIntervalSince(lastAB)

            if timeSinceLastAB >= AB_DELAY_SECONDS {
                // Ready to process - execute next call immediately
                executeNextCall()

                // Schedule next call with 1-second delay
                if !callQueue.isEmpty {
                    scheduleNextCall(delay: CONSECUTIVE_DELAY_SECONDS)
                } else {
                    isProcessingQueue = false
                }
            } else {
                // Wait for 5-second threshold after A/B activity
                let remainingDelay = AB_DELAY_SECONDS - timeSinceLastAB
                scheduleNextCall(delay: remainingDelay)
            }
        } else {
            // No A/B activity yet - add initial 1-second delay before processing
            scheduleNextCall(delay: CONSECUTIVE_DELAY_SECONDS)
        }
    }

    private func executeNextCall() {
        guard !callQueue.isEmpty else { return }

        // CRITICAL: Check for cancellation before executing Call C
        // Prevents sentiment analysis from running on cancelled requests
        // (e.g., "Add this to my like list" → user cancels → shouldn't add to list)
        if let openAI = openAIService, openAI.isCancellationRequested {
            AppLogger.standard("🛑 Call C cancelled: User pressed STOP (clearing queue)")
            clearQueue()
            return
        }

        let context = callQueue.removeFirst()

        AppLogger.standard("🚀 Executing Call C: \(context.userMessage)")

        // Delegate actual Call C execution to SentimentAnalysisService
        Task {
            guard let delegate = sentimentDelegate else {
                AppLogger.standard("⚠️ Call C: No sentiment analysis delegate set")
                return
            }

            guard let apiKey = self.apiKey else {
                AppLogger.standard("⚠️ Call C: No API key available")
                return
            }

            await delegate.executeSentimentAnalysis(context: context, apiKey: apiKey)

            AppLogger.standard("✅ Call C completed: \(context.userMessage)")
        }
    }

    private func scheduleNextCall(delay: Double) {
        dispatchTimer?.invalidate()

        dispatchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.processQueue()
            }
        }

        AppLogger.standard("⏰ Call C scheduled in \(String(format: "%.1f", delay)) seconds")
    }

    // MARK: - Debug Information

    /// Get current queue status for debugging
    func getQueueStatus() -> String {
        let timeSinceAB = lastABActivity.map { Date().timeIntervalSince($0) } ?? -1
        return "Queue: \(callQueue.count), Last A/B: \(String(format: "%.1f", timeSinceAB))s ago, Processing: \(isProcessingQueue)"
    }
}

// MARK: - Logging Helper Extension
extension AppLogger {
    static func callCDispatch(_ message: String) {
        AppLogger.standard("🔄 CallC: \(message)")
    }
}
//
//  BugReportView.swift
//  Cool Uncle
//
//  Phase 1: Bug Report UI with Enhanced Metadata Collection
//  See: proposals/bug_report.md
//

import SwiftUI

struct BugReportView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var zaparooService: ZaparooService
    @ObservedObject var settings: AppSettings
    @ObservedObject var enhancedOpenAIService: EnhancedOpenAIService
    @ObservedObject var speechService: SpeechService

    let lastTranscription: String

    @State private var asrText: String
    @State private var expectedBehavior: String = ""
    @State private var isSubmitting: Bool = false
    @State private var showSuccessAlert: Bool = false
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var reportID: String = ""

    init(
        zaparooService: ZaparooService,
        settings: AppSettings,
        enhancedOpenAIService: EnhancedOpenAIService,
        speechService: SpeechService,
        lastTranscription: String
    ) {
        self.zaparooService = zaparooService
        self.settings = settings
        self.enhancedOpenAIService = enhancedOpenAIService
        self.speechService = speechService
        self.lastTranscription = lastTranscription

        // Pre-fill ASR text with last transcription
        _asrText = State(initialValue: lastTranscription)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Form content
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Field 1: What did you say?
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What did you say?")
                                .font(.headline)

                            Text("Edit the text if speech recognition got it wrong")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("What you said...", text: $asrText, axis: .vertical)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                                .lineLimit(3...6)
                        }

                        // Field 2: What should have happened?
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What should have happened?")
                                .font(.headline)

                            Text("Describe the expected behavior")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Expected behavior...", text: $expectedBehavior, axis: .vertical)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                                .lineLimit(3...6)
                        }

                        // Info text
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("Session logs will be attached automatically")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                }

                // Bottom action buttons
                HStack(spacing: 16) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)

                    Button(action: submitBugReport) {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Send Report")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(asrText.isEmpty || expectedBehavior.isEmpty || isSubmitting)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.gray.opacity(0.3)),
                    alignment: .top
                )
            }
            .navigationTitle("Report Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .alert("Bug Report Submitted", isPresented: $showSuccessAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Thank you! Your report has been submitted.\n\nReport ID: \(reportID)")
        }
        .alert("Submission Failed", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Bug Report Submission

    private func submitBugReport() {
        isSubmitting = true

        Task {
            do {
                let metadata = collectBugReportMetadata()
                let submittedReportID = try await CloudflareService.shared.submitBugReport(metadata)

                await MainActor.run {
                    reportID = submittedReportID
                    isSubmitting = false
                    showSuccessAlert = true
                    AppLogger.standard("🐛 Bug report submitted successfully: \(submittedReportID)")
                }
            } catch CloudflareError.rateLimitExceeded(let retryAfterSeconds) {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "You've submitted too many reports. Please try again in \(retryAfterSeconds / 60) minutes."
                    showErrorAlert = true
                    AppLogger.standard("⚠️ Bug report rate limited: \(retryAfterSeconds)s")
                }
            } catch CloudflareError.invalidURL {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "Configuration error: Invalid server URL.\n\nPlease contact support."
                    showErrorAlert = true
                    AppLogger.standard("❌ Bug report failed: Invalid URL")
                }
            } catch CloudflareError.httpError {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "Server error: Unable to submit bug report.\n\nPlease check your internet connection and try again.\n\nIf this persists, the server may be down."
                    showErrorAlert = true
                    AppLogger.standard("❌ Bug report failed: HTTP error")
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "Failed to submit: \(error.localizedDescription)\n\nPlease check your internet connection and try again."
                    showErrorAlert = true
                    AppLogger.standard("❌ Bug report submission failed: \(error)")
                }
            }
        }
    }

    // MARK: - Metadata Collection

    /// Collect all automated metadata fields
    private func collectBugReportMetadata() -> CloudflareService.BugReportMetadata {
        // Get app version and build number
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        // Get iOS version and specific device model
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = DeviceInfo.getDeviceModel()

        // Get connection state
        let connectionState: String
        switch zaparooService.connectionState {
        case .connected:
            connectionState = "connected"
        case .connecting:
            connectionState = "connecting"
        case .disconnected:
            connectionState = "disconnected"
        case .error(let error):
            connectionState = "error: \(error)"
        }

        // Get available systems
        let availableSystems = zaparooService.availableSystems

        // Get game context
        let currentGameName = CurrentGameService.shared.currentGameName
        let currentGameSystem = CurrentGameService.shared.currentGameSystem
        let lastLaunchedGame = zaparooService.lastLaunchedGameName

        // Get AI context
        let lastActionType = enhancedOpenAIService.threeCallContext?.actionType
        let aiResponsePresent = !enhancedOpenAIService.coolUncleResponse.isEmpty
        let commandGenerated = enhancedOpenAIService.generatedCommand != nil

        // Get speech recognition state
        let speechAuthorized = speechService.isAuthorized
        let siriEnablementRequired = speechService.requiresSiriEnablement

        // Get full session log
        let fullSessionLog = AppLogger.getSessionLog()

        // Determine if user modified ASR transcription
        let userCorrected: String? = (asrText != lastTranscription) ? asrText : nil

        return CloudflareService.BugReportMetadata(
            asrOriginal: lastTranscription,
            userCorrected: userCorrected,
            expectedBehavior: expectedBehavior,
            appVersion: appVersion,
            buildNumber: buildNumber,
            iosVersion: iosVersion,
            deviceModel: deviceModel,
            misterConnectionState: connectionState,
            misterIPAddress: settings.misterIPAddress,
            availableSystems: availableSystems,
            currentGameName: currentGameName,
            currentGameSystem: currentGameSystem,
            lastLaunchedGame: lastLaunchedGame,
            lastActionType: lastActionType,
            aiResponsePresent: aiResponsePresent,
            commandGenerated: commandGenerated,
            speechAuthorized: speechAuthorized,
            siriEnablementRequired: siriEnablementRequired,
            fullSessionLog: fullSessionLog
        )
    }
}

// MARK: - Preview

#Preview {
    let settings = AppSettings()
    let zaparooService = ZaparooService(settings: settings)
    let enhancedOpenAIService = EnhancedOpenAIService()
    let speechService = SpeechService()

    return BugReportView(
        zaparooService: zaparooService,
        settings: settings,
        enhancedOpenAIService: enhancedOpenAIService,
        speechService: speechService,
        lastTranscription: "launch super mario"
    )
}

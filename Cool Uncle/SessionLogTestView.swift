//
//  SessionLogTestView.swift
//  Cool Uncle
//
//  Test harness for verifying session log capture
//

import SwiftUI

struct SessionLogTestView: View {
    @State private var sessionLog: String = ""
    @State private var logLineCount: Int = 0
    @State private var exportMessage: String = ""
    @State private var showingShareSheet = false
    @State private var shareFileURL: URL?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Test buttons
                VStack(spacing: 12) {
                    Text("Session Log Test Harness")
                        .font(.headline)

                    Button("Generate Test Logs") {
                        generateTestLogs()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Retrieve Session Log") {
                        retrieveSessionLog()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Session Log") {
                        clearSessionLog()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button("Share Session Log") {
                        shareSessionLog()
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)

                    Text("\(logLineCount) lines captured")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !exportMessage.isEmpty {
                        Text(exportMessage)
                            .font(.caption2)
                            .foregroundColor(.green)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()

                Divider()

                // Log display
                ScrollView {
                    Text(sessionLog.isEmpty ? "No logs captured yet. Tap 'Generate Test Logs' to test." : sessionLog)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
                .padding()
            }
            .navigationTitle("Session Log Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = shareFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
    }

    func generateTestLogs() {
        // Simulate different types of logs
        AppLogger.standard("🔍 Test: Executing search for: Mario")
        AppLogger.userInput("Test user said: Launch Mario")
        AppLogger.openAI("🎯 CALL A: Test generating JSON command")
        AppLogger.openAI("✅ CALL A: Test command generated")
        AppLogger.connection("🔌 Test: Connected to MiSTer")
        AppLogger.misterRequest("{\"method\":\"launch\",\"params\":{\"text\":\"test\"}}")
        AppLogger.misterResponse("{\"result\":\"success\"}")
        AppLogger.openAI("🎯 CALL B: Test generating speech")
        AppLogger.openAI("✅ CALL B: Test speech generated")
        AppLogger.session("🔄 Test: Session started")
        AppLogger.verbose("🔧 Test: Verbose debug log")
        AppLogger.standard("ℹ️ Test: Standard info message")

        // Retrieve immediately to show results
        retrieveSessionLog()
    }

    func retrieveSessionLog() {
        sessionLog = AppLogger.getSessionLog()
        logLineCount = sessionLog.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    func clearSessionLog() {
        AppLogger.clearSessionLog()
        sessionLog = ""
        logLineCount = 0
    }

    func shareSessionLog() {
        let log = AppLogger.getSessionLog()
        let timestamp = Date().timeIntervalSince1970
        let filename = "session_log_\(timestamp).txt"

        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            exportMessage = "❌ Failed to access Documents directory"
            return
        }

        let fileURL = documentsPath.appendingPathComponent(filename)

        do {
            try log.write(to: fileURL, atomically: true, encoding: .utf8)
            shareFileURL = fileURL
            showingShareSheet = true
            exportMessage = "✅ File created, opening share sheet..."
            print("📁 Session log saved to: \(fileURL.path)")
        } catch {
            exportMessage = "❌ Export failed: \(error.localizedDescription)"
            print("❌ Failed to export session log: \(error)")
        }
    }
}

// Share Sheet wrapper for UIActivityViewController
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SessionLogTestView()
}

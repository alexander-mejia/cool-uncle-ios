import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showingClearHistoryAlert = false
    
    // Local state for IP address to avoid system keyboard issues
    @State private var localIPAddress: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("OpenAI Configuration") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.headline)
                        SecureField("Enter your OpenAI API key", text: $settings.openAIAPIKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .textContentType(.password)
                            .autocorrectionDisabled(true)
                            .keyboardType(.asciiCapable)
                        Text("Get your API key from platform.openai.com")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("MiSTer Configuration") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MiSTer IP Address")
                            .font(.headline)
                        TextField("192.168.1.100", text: $localIPAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled(true)
                            .textContentType(.none)
                            .onSubmit {
                                // Only update settings when user submits/finishes editing
                                settings.misterIPAddress = localIPAddress
                            }
                            .onChange(of: localIPAddress) { oldValue, newValue in
                                // Immediate visual update, delayed save via debouncing
                                settings.misterIPAddress = newValue
                            }
                        Text("The IP address of your MiSTer FPGA on your local network")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Voice Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Text-to-Speech Voice")
                            .font(.headline)
                        Picker("Voice", selection: $settings.selectedVoiceIdentifier) {
                            Text("Default").tag("")
                            ForEach(AppSettings.availableVoices, id: \.identifier) { voice in
                                Text(voiceDisplayName(for: voice)).tag(voice.identifier)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        Text("Voice used for speaking AI responses")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Data Management") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommendation Variety")
                            .font(.headline)
                        HStack {
                            Text("Don't recommend games played in the last")
                            Spacer()
                            Picker("Days", selection: $settings.avoidGamesDays) {
                                ForEach(1...30, id: \.self) { days in
                                    Text("\(days) day\(days == 1 ? "" : "s")").tag(days)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(maxWidth: 120)
                        }
                        Text("Higher values increase variety but may exclude more games")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommendation Confirmation")
                            .font(.headline)
                        HStack {
                            Text("Ask before switching games after")
                            Spacer()
                            Picker("Minutes", selection: $settings.recommendConfirmMinutes) {
                                Text("Never").tag(0)
                                ForEach(1...4, id: \.self) { minutes in
                                    Text("\(minutes) min\(minutes == 1 ? "" : "s")").tag(minutes)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(maxWidth: 120)
                        }
                        Text("While playing, recommendations wait for your confirmation instead of launching immediately")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    NavigationLink(destination: GamePreferenceView()) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Game Preferences")
                                .font(.headline)
                            Text("View and manage your game history, favorites, and preferences")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Clear Gaming History") {
                            showingClearHistoryAlert = true
                        }
                        .foregroundColor(.red)
                        
                        Text("Removes all stored game commands and preferences. This helps the AI provide personal recommendations.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .alert("Clear Gaming History", isPresented: $showingClearHistoryAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Delete All History", role: .destructive) {
                            UserGameHistoryService.shared.clearUserHistory()
                            GamePreferenceService.shared.clearAllPreferences()
                        }
                    } message: {
                        Text("This will permanently delete all your gaming history, preferences, and AI recommendations data. This action cannot be undone.")
                    }
                    
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Initialize local state to avoid binding to Published property during text editing
            localIPAddress = settings.misterIPAddress
        }
    }
    
    // Helper function to show voice quality
    private func voiceDisplayName(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:
            return "\(voice.name) (Premium)"
        case .enhanced:
            return "\(voice.name) (Enhanced)"
        default:
            return voice.name
        }
    }
}


#Preview {
    SettingsView(settings: AppSettings())
}
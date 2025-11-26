import SwiftUI

struct ConnectionView: View {
    @ObservedObject var zaparooService: ZaparooService
    @ObservedObject var settings: AppSettings
    @State private var ipAddress: String = ""
    @State private var isConnecting: Bool = false
    @State private var showingSettings = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Spacer()
                
                // Logo/Title
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("Cool Uncle")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Voice Control for MiSTer FPGA")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                // Connection Section
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MiSTer IP Address")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        TextField("192.168.1.100", text: $ipAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numbersAndPunctuation)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        
                        Text("Enter the IP address of your MiSTer FPGA on your local network")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    
                    // Connection Status
                    if zaparooService.connectionState != .disconnected {
                        HStack {
                            Circle()
                                .fill(connectionStatusColor)
                                .frame(width: 12, height: 12)
                            
                            Text(connectionStatusText)
                                .font(.subheadline)
                                .foregroundColor(connectionStatusColor)
                        }
                        .padding()
                        .background(connectionStatusColor.opacity(0.1))
                        .cornerRadius(10)
                    }
                    
                    // Error Display
                    if !zaparooService.lastError.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Connection Failed")
                                    .font(.headline)
                                    .foregroundColor(.red)
                            }
                            
                            Text(zaparooService.lastError)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(10)
                    }
                    
                    // Connect Button
                    Button(action: connectToMiSTer) {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "wifi")
                            }
                            
                            Text(isConnecting ? "Connecting..." : "Connect to MiSTer")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(buttonBackgroundColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(ipAddress.isEmpty || isConnecting)
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // Quick Setup Help
                VStack(spacing: 8) {
                    Link("Need Help?", destination: URL(string: "https://human-interact.com/cool-uncle/support/")!)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Cool Uncle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: settings)
        }
        .onAppear {
            // Pre-fill with saved IP address
            ipAddress = settings.misterIPAddress
        }
        .onChange(of: zaparooService.connectionState) { oldState, newState in
            // Update connecting state based on connection status
            switch newState {
            case .connecting:
                isConnecting = true
            case .connected, .disconnected, .error:
                isConnecting = false
            }
            
            // Save successful IP address
            if case .connected = newState {
                settings.misterIPAddress = ipAddress
            }
        }
    }
    
    // MARK: - Computed Properties
    private var connectionStatusColor: Color {
        switch zaparooService.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var connectionStatusText: String {
        switch zaparooService.connectionState {
        case .connected:
            return "Connected successfully!"
        case .connecting:
            return "Connecting to MiSTer..."
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Connection failed"
        }
    }
    
    private var buttonBackgroundColor: Color {
        if ipAddress.isEmpty || isConnecting {
            return .gray
        } else {
            return .blue
        }
    }
    
    // MARK: - Methods
    private func connectToMiSTer() {
        guard !ipAddress.isEmpty else { return }
        
        // Validate IP format (basic check)
        let trimmedIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Simple IP validation
        if !isValidIPAddress(trimmedIP) && !isValidHostname(trimmedIP) {
            zaparooService.lastError = "Please enter a valid IP address or hostname"
            return
        }
        
        zaparooService.connect(to: trimmedIP)
    }
    
    private func isValidIPAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        
        return parts.allSatisfy { part in
            guard let num = Int(part), num >= 0, num <= 255 else { return false }
            return true
        }
    }
    
    private func isValidHostname(_ hostname: String) -> Bool {
        // Basic hostname validation - allows letters, numbers, dots, and hyphens
        let hostnameRegex = "^[a-zA-Z0-9.-]+$"
        let predicate = NSPredicate(format: "SELF MATCHES %@", hostnameRegex)
        return predicate.evaluate(with: hostname) && !hostname.isEmpty
    }
}

#Preview {
    let settings = AppSettings()
    ConnectionView(
        zaparooService: ZaparooService(settings: settings),
        settings: settings
    )
}

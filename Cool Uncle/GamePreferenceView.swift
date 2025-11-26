import SwiftUI

/// Displays user's game preferences across multiple categorized lists
///
/// **Features**:
/// - 🎮 Played Games - All games user has played or tried
/// - 👎 Disliked Games - Games user rejected or didn't enjoy  
/// - ⭐ Want to Play - Games user expressed interest in
/// - ❤️ Favorites - Games user loved or highly rated
/// - Interactive management (move between categories, delete)
/// - Statistics and insights about gaming preferences
///
/// **Integration**: Accessible from Settings menu and main navigation

struct GamePreferenceView: View {
    @StateObject private var preferenceService = GamePreferenceService.shared
    @State private var selectedCategory: GamePreferenceService.PreferenceCategory = .played
    @State private var showingClearAlert = false
    @State private var categoryToClear: GamePreferenceService.PreferenceCategory?
    @State private var showingGameDetail: GamePreferenceService.GamePreference?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Category Selector
                categoryPicker
                
                // Game List
                gameList
            }
            .navigationTitle("Game Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Clear \(selectedCategory.displayName)") {
                            categoryToClear = selectedCategory
                            showingClearAlert = true
                        }
                        
                        Button("Clear All Preferences", role: .destructive) {
                            categoryToClear = nil
                            showingClearAlert = true
                        }
                        
                        Button("Export Preferences") {
                            exportPreferences()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Clear Preferences", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                if let category = categoryToClear {
                    preferenceService.clearCategory(category)
                } else {
                    preferenceService.clearAllPreferences()
                }
            }
        } message: {
            if let category = categoryToClear {
                Text("This will permanently remove all games from \(category.displayName).")
            } else {
                Text("This will permanently remove all your game preferences.")
            }
        }
        .sheet(item: $showingGameDetail) { preference in
            GameDetailView(preference: preference, preferenceService: preferenceService)
        }
    }
    
    // MARK: - Category Picker
    
    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(GamePreferenceService.PreferenceCategory.allCases, id: \.self) { category in
                    CategoryChip(
                        category: category,
                        count: preferenceService.getGames(in: category).count,
                        isSelected: selectedCategory == category
                    ) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    // MARK: - Game List
    
    private var gameList: some View {
        let games = preferenceService.getGames(in: selectedCategory)
        
        return Group {
            if games.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(games, id: \.gameName) { preference in
                        GameRowView(preference: preference) {
                            showingGameDetail = preference
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                preferenceService.removeGame(preference.gameName, from: selectedCategory)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            ForEach(otherCategories(excluding: selectedCategory), id: \.self) { category in
                                Button(category.emoji) {
                                    preferenceService.moveGame(preference.gameName, from: selectedCategory, to: category)
                                }
                                .tint(categoryColor(for: category))
                            }
                        }
                    }
                    
                    // Statistics footer
                    if !games.isEmpty {
                        statisticsFooter(for: games)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedCategory.systemImage)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No \(selectedCategory.displayName.lowercased()) yet")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(emptyStateMessage(for: selectedCategory))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    // MARK: - Statistics Footer
    
    private func statisticsFooter(for games: [GamePreferenceService.GamePreference]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Statistics")
                .font(.headline)
                .padding(.bottom, 4)
            
            HStack {
                Text("Total Games:")
                Spacer()
                Text("\(games.count)")
                    .foregroundColor(.secondary)
            }
            
            if let oldestGame = games.min(by: { $0.timestamp < $1.timestamp }) {
                HStack {
                    Text("Since:")
                    Spacer()
                    Text(oldestGame.timestamp, style: .date)
                        .foregroundColor(.secondary)
                }
            }
            
            let sourceCounts = Dictionary(grouping: games, by: { $0.source }).mapValues { $0.count }
            ForEach(sourceCounts.sorted(by: { $0.value > $1.value }), id: \.key) { source, count in
                HStack {
                    Text("\(source.displayName):")
                    Spacer()
                    Text("\(count)")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(8)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    // MARK: - Helper Methods
    
    private func otherCategories(excluding category: GamePreferenceService.PreferenceCategory) -> [GamePreferenceService.PreferenceCategory] {
        return GamePreferenceService.PreferenceCategory.allCases.filter { $0 != category }
    }
    
    private func categoryColor(for category: GamePreferenceService.PreferenceCategory) -> Color {
        switch category {
        case .played: return .blue
        case .disliked: return .red
        case .wantToPlay: return .orange
        case .favorites: return .pink
        }
    }
    
    private func emptyStateMessage(for category: GamePreferenceService.PreferenceCategory) -> String {
        switch category {
        case .played:
            return "Games you've launched or said you've already played will appear here."
        case .disliked:
            return "Games you don't like or have rejected will appear here."
        case .wantToPlay:
            return "Games you've expressed interest in trying will appear here."
        case .favorites:
            return "Games you love or have highly rated will appear here."
        }
    }
    
    private func exportPreferences() {
        let breakdown = preferenceService.getDetailedBreakdown()
        let activityController = UIActivityViewController(
            activityItems: [breakdown],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityController, animated: true)
        }
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let category: GamePreferenceService.PreferenceCategory
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(category.emoji)
                Text(category.rawValue.capitalized)
                    .font(.subheadline)
                if count > 0 {
                    Text("(\(count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(UIColor.tertiarySystemGroupedBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Game Row

struct GameRowView: View {
    let preference: GamePreferenceService.GamePreference
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preference.gameName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text(preference.timestamp, style: .date)
                        Text("•")
                        Text(preference.source.displayName)
                        
                        if let context = preference.context {
                            Text("•")
                            Text(context)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Game Detail View

struct GameDetailView: View {
    let preference: GamePreferenceService.GamePreference
    let preferenceService: GamePreferenceService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var currentGameService = CurrentGameService.shared
    @State private var isLaunching = false
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Game")
                        Spacer()
                        Text(preference.gameName)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Category")
                        Spacer()
                        Text(preference.category.displayName)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Added")
                        Spacer()
                        Text(preference.timestamp, style: .date)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Source")
                        Spacer()
                        Text(preference.source.displayName)
                            .foregroundColor(.secondary)
                    }
                    
                    if let context = preference.context {
                        HStack {
                            Text("Context")
                            Spacer()
                            Text(context)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("Actions") {
                    // Launch Game button - show if this game has a cached launch command
                    // Check if game has a launch command for the Play button
                    
                    if let launchCommand = preference.launchCommand {
                        Button(action: {
                            launchGame(with: launchCommand)
                        }) {
                            HStack {
                                Image(systemName: "gamecontroller.fill")
                                VStack(alignment: .leading) {
                                    Text("Launch Game")
                                        .font(.headline)
                                    Text("Re-launch from preferences")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isLaunching {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isLaunching)
                        .foregroundColor(.primary)
                    }
                    
                    ForEach(GamePreferenceService.PreferenceCategory.allCases, id: \.self) { category in
                        if category != preference.category {
                            Button("Move to \(category.displayName)") {
                                preferenceService.moveGame(preference.gameName, from: preference.category, to: category)
                                dismiss()
                            }
                        }
                    }
                    
                    Button("Remove from \(preference.category.displayName)", role: .destructive) {
                        preferenceService.removeGame(preference.gameName, from: preference.category)
                        dismiss()
                    }
                }
            }
            .navigationTitle(preference.gameName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - Launch Game Action
    
    private func launchGame(with launchCommand: String) {
        isLaunching = true
        AppLogger.gameHistory("🎮 Launching game from preferences: \(preference.gameName)")
        
        // Parse the launch command to extract the media path
        if let commandData = launchCommand.data(using: .utf8),
           let commandDict = try? JSONSerialization.jsonObject(with: commandData) as? [String: Any],
           let params = commandDict["params"] as? [String: Any],
           let text = params["text"] as? String {
            
            // Send launch command via ZaparooService
            // We need access to ZaparooService - for now we'll use notification
            AppLogger.gameHistory("🚀 Sending launch command: \(text)")
            
            // Use NotificationCenter to trigger the launch
            NotificationCenter.default.post(
                name: Notification.Name("LaunchGameFromPreferences"),
                object: nil,
                userInfo: ["launchCommand": launchCommand, "gameName": preference.gameName]
            )
            
            // Reset launching state after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                isLaunching = false
            }
        } else {
            AppLogger.standard("❌ Failed to parse launch command for \(preference.gameName)")
            isLaunching = false
        }
    }
}

// MARK: - Extensions

extension GamePreferenceService.PreferenceCategory {
    var systemImage: String {
        switch self {
        case .played: return "gamecontroller.fill"
        case .disliked: return "hand.thumbsdown.fill"
        case .wantToPlay: return "star.fill"
        case .favorites: return "heart.fill"
        }
    }
}

extension GamePreferenceService.PreferenceSource {
    var displayName: String {
        switch self {
        case .launchCommand: return "Launched"
        case .aiSentiment: return "AI Detected" 
        case .manual: return "Manual"
        case .conversation: return "Conversation"
        }
    }
}

// MARK: - Previews

struct GamePreferenceView_Previews: PreviewProvider {
    static var previews: some View {
        GamePreferenceView()
    }
}
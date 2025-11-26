import SwiftUI
import Foundation

@main
struct Cool_UncleApp: App {
    init() {
        // Minimal startup for performance
    }

    var body: some Scene {
        WindowGroup {
            MainAppView()
                .onAppear {
                    // Move heavy operations to background to prevent UI hangs
                    Task(priority: .background) {
                        AppLogger.logConfiguration()
                        // Removed logSystemPrompts() - clutters session logs for bug reporting
                        // System prompts are in source code (three-call-architecture.md)
                    }

                    // One-time migration: restore games with launch commands to played category (async)
                    Task(priority: .utility) {
                        GamePreferenceService.shared.restorePlayedGamesWithLaunchCommands()
                    }
                }
        }
    }
}
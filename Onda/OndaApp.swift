//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()
    @State private var subscriptions: SubscriptionService

    init() {
        do {
            let c = try ModelContainer(for: Schema(ondaSchema))
            container = c
            _subscriptions = State(initialValue:
                SubscriptionService(modelContext: c.mainContext, feeds: RSSFeedClient()))
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .environment(subscriptions)
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}

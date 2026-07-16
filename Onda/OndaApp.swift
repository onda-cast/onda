//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()

    init() {
        do {
            container = try ModelContainer(for: Schema(ondaSchema))
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}

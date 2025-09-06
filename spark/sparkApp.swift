//
//  sparkApp.swift
//  spark
//
//  Created by Cary on 2025/8/31.
//

import SwiftUI
import SwiftData

@main
struct sparkApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            Conversation.self,
            ChatMessageData.self,
            AttachmentData.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(content: {
            ContentView()
                .environment(\.modelContext, sharedModelContainer.mainContext)
        })
        .modelContainer(sharedModelContainer)
    }
}

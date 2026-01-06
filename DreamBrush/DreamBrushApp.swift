//
//  DreamBrushApp.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import Foundation
import SwiftUI

@main
struct DreamBrushApp: App {
    @State private var importAlert: ImportAlert?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .alert(item: $importAlert) { alert in
                    Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        do {
            let asset = try SplatAssetManager.shared.importAsset(from: url)
            NotificationCenter.default.post(name: .splatAssetsDidChange, object: nil)
            importAlert = ImportAlert(
                title: "Import Complete",
                message: "Imported \(asset.name)."
            )
        } catch {
            importAlert = ImportAlert(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct ImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

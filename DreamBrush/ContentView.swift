//
//  ContentView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

// MARK: - Tab Bar Visibility Manager

@Observable
final class TabBarVisibilityManager {
    var isHidden = false
}

struct ContentView: View {
    @State private var selectedTab: Tab = .capture
    @State private var tabBarVisibility = TabBarVisibilityManager()

    enum Tab: String, CaseIterable {
        case capture = "Capture"
        case viewer = "Viewer"
        case library = "Library"

        var icon: String {
            switch self {
            case .capture: return "camera.viewfinder"
            case .viewer: return "cube.transparent"
            case .library: return "folder"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureView()
                .tabItem {
                    Label(Tab.capture.rawValue, systemImage: Tab.capture.icon)
                }
                .tag(Tab.capture)

            ViewerView()
                .tabItem {
                    Label(Tab.viewer.rawValue, systemImage: Tab.viewer.icon)
                }
                .tag(Tab.viewer)

            LibraryView()
                .tabItem {
                    Label(Tab.library.rawValue, systemImage: Tab.library.icon)
                }
                .tag(Tab.library)
        }
        .environment(tabBarVisibility)
        .toolbar(tabBarVisibility.isHidden ? .hidden : .visible, for: .tabBar)
        .animation(.easeInOut(duration: 0.2), value: tabBarVisibility.isHidden)
    }
}

#Preview {
    ContentView()
}

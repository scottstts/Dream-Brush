//
//  ARViewContainer.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import ARKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true

        // Show feature points and world origin for debugging
        #if DEBUG
        arView.debugOptions = [.showFeaturePoints]
        #endif

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Session is managed externally
    }
}

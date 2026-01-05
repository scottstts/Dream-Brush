//
//  ViewerView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

struct ViewerView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "cube.transparent")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)

                Text("Viewer Mode")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("View 3D Gaussian Splats in AR with relocalization")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()

                Text("No splat assets imported yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 40)
            }
            .navigationTitle("Viewer")
        }
    }
}

#Preview {
    ViewerView()
}

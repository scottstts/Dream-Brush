//
//  CaptureView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

struct CaptureView: View {
    @State private var showingCaptureSession = false
    @State private var recentBundles: [CaptureBundle] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)

                Text("Capture Mode")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Guided multi-angle capture for SHARP splats")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // Recent captures summary
                if !recentBundles.isEmpty {
                    recentCapturesView
                }

                Spacer()

                // Start Capture button
                Button(action: { showingCaptureSession = true }) {
                    Label("Start Capture", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
            .navigationTitle("Capture")
            .fullScreenCover(isPresented: $showingCaptureSession) {
                NavigationStack {
                    CaptureSessionView()
                }
            }
            .onAppear {
                loadRecentBundles()
            }
            .onChange(of: showingCaptureSession) { _, isShowing in
                if !isShowing {
                    // Refresh bundles when returning from capture
                    loadRecentBundles()
                }
            }
        }
    }

    private var recentCapturesView: some View {
        VStack(spacing: 8) {
            Text("Recent Captures")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(recentBundles.prefix(3)) { bundle in
                    VStack(spacing: 4) {
                        BundleThumbnailView(
                            bundle: bundle,
                            size: 60,
                            placeholderSystemImage: "photo.stack"
                        )

                        Text("\(bundle.manifest.captureStats.frameCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func loadRecentBundles() {
        Task {
            let bundles = await CaptureBundleManager.shared.listBundlesAsync()
            await MainActor.run {
                recentBundles = bundles
            }
        }
    }
}

#Preview {
    CaptureView()
}

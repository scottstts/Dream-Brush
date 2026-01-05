//
//  LibraryView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

struct LibraryView: View {
    @State private var capturedBundles: [CaptureBundle] = []
    @State private var splatAssets: [SplatAsset] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Capture Bundles") {
                    if capturedBundles.isEmpty {
                        ContentUnavailableView(
                            "No Captures",
                            systemImage: "camera.viewfinder",
                            description: Text("Captured scans will appear here")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(capturedBundles) { bundle in
                            CaptureBundleRow(bundle: bundle)
                        }
                    }
                }

                Section("Splat Assets") {
                    if splatAssets.isEmpty {
                        ContentUnavailableView(
                            "No Splat Assets",
                            systemImage: "cube.transparent",
                            description: Text("Import trained 3DGS assets to view in AR")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(splatAssets) { asset in
                            SplatAssetRow(asset: asset)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: importSplatAsset) {
                            Label("Import Splat Asset", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                loadLibrary()
            }
        }
    }

    private func loadLibrary() {
        capturedBundles = CaptureBundleManager.shared.listBundles()
        // TODO: Load splat assets
    }

    private func importSplatAsset() {
        // TODO: Implement splat asset import via document picker
    }
}

struct CaptureBundleRow: View {
    let bundle: CaptureBundle

    var body: some View {
        HStack {
            if let thumbnail = bundle.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "camera.viewfinder")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.manifest.bundleId.prefix(8) + "...")
                    .font(.headline)

                Text(bundle.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Label("\(bundle.manifest.captureStats.frameCount)", systemImage: "photo.stack")
                    if bundle.manifest.captureSettings.depthEnabled {
                        Label("\(bundle.manifest.captureStats.depthFrameCount)", systemImage: "cube")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct SplatAssetRow: View {
    let asset: SplatAsset

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.2))
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "cube.transparent.fill")
                        .foregroundStyle(.blue)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name)
                    .font(.headline)

                Text(asset.formattedFileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    LibraryView()
}

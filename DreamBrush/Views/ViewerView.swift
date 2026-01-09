//
//  ViewerView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

struct ViewerView: View {
    @State private var splatAssets: [SplatAsset] = []
    @State private var captureBundles: [CaptureBundle] = []
    @AppStorage("viewerRelocalizationEnabled") private var relocalizationEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section("Viewer Settings") {
                    Toggle("Relocalization", isOn: $relocalizationEnabled)
                }

                if splatAssets.isEmpty {
                    viewerEmptyState
                } else {
                    if !linkedAssets.isEmpty {
                        Section("Ready to View") {
                            ForEach(linkedAssets, id: \.0.id) { asset, bundle in
                                NavigationLink {
                                    ViewerSessionView(
                                        asset: asset,
                                        bundle: bundle,
                                        relocalizationEnabled: relocalizationEnabled
                                    )
                                } label: {
                                    SplatAssetRow(asset: asset)
                                }
                            }
                        }
                    }

                    if !unlinkedAssets.isEmpty {
                        Section("Needs Linking") {
                            ForEach(unlinkedAssets) { asset in
                                VStack(alignment: .leading, spacing: 6) {
                                    SplatAssetRow(asset: asset)
                                        .opacity(0.7)

                                    Text("Link a capture bundle in Library to enable viewing.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 76)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Viewer")
            .task {
                await loadData()
            }
            .refreshable {
                await loadData()
            }
        }
    }

    private var bundlesById: [String: CaptureBundle] {
        Dictionary(uniqueKeysWithValues: captureBundles.map { ($0.id, $0) })
    }

    private var linkedAssets: [(SplatAsset, CaptureBundle)] {
        splatAssets.compactMap { asset -> (SplatAsset, CaptureBundle)? in
            guard let bundleId = asset.associatedBundleId,
                  let bundle = bundlesById[bundleId] else {
                return nil
            }
            return (asset, bundle)
        }
    }

    private var unlinkedAssets: [SplatAsset] {
        splatAssets.filter { asset in
            guard let bundleId = asset.associatedBundleId else { return true }
            return bundlesById[bundleId] == nil
        }
    }

    private var viewerEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No splat assets yet")
                .font(.headline)

            Text("Import a splat asset in Library, then link it to a capture bundle to view it in AR.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }

    @MainActor
    private func loadData() async {
        splatAssets = await SplatAssetManager.shared.listAssetsAsync()
        captureBundles = await CaptureBundleManager.shared.listBundlesAsync()
    }
}

#Preview {
    ViewerView()
}

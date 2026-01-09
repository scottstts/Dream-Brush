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
    @State private var isReadyToViewExpanded = true
    @State private var isLinkingNeededExpanded = true
    @AppStorage("viewerRelocalizationEnabled") private var relocalizationEnabled = true

    var body: some View {
        NavigationStack {
            List {
                // Settings Section
                Section {
                    Toggle(isOn: $relocalizationEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "location.viewfinder")
                                .font(.system(size: 18))
                                .foregroundStyle(relocalizationEnabled ? .blue : .secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Relocalization")
                                    .font(.body)
                                Text(relocalizationEnabled ? "Align splats to real world" : "View without alignment")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.blue)
                }

                if splatAssets.isEmpty {
                    viewerEmptyState
                } else {
                    // Ready to View section
                    if !readyToViewAssets.isEmpty {
                        Section {
                            if isReadyToViewExpanded {
                                ForEach(readyToViewAssets, id: \.asset.id) { item in
                                    NavigationLink {
                                        ViewerSessionView(
                                            asset: item.asset,
                                            bundle: item.bundle,
                                            relocalizationEnabled: relocalizationEnabled
                                        )
                                    } label: {
                                        ViewerAssetRow(asset: item.asset, isLinked: item.bundle != nil)
                                    }
                                }
                            }
                        } header: {
                            Button {
                                withAnimation {
                                    isReadyToViewExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Label("Ready to View", systemImage: "play.circle.fill")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(isReadyToViewExpanded ? 90 : 0))
                                }
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .textCase(nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Linking Needed section (only when relocalization is ON)
                    if relocalizationEnabled && !linkingNeededAssets.isEmpty {
                        Section {
                            if isLinkingNeededExpanded {
                                ForEach(linkingNeededAssets) { asset in
                                    VStack(alignment: .leading, spacing: 8) {
                                        ViewerAssetRow(asset: asset, isLinked: false)
                                            .opacity(0.6)

                                        HStack(spacing: 6) {
                                            Image(systemName: "link.badge.plus")
                                                .font(.caption2)
                                            Text("Link a capture bundle in Library to enable viewing")
                                                .font(.caption)
                                        }
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 72)
                                    }
                                }
                            }
                        } header: {
                            Button {
                                withAnimation {
                                    isLinkingNeededExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Label("Linking Needed", systemImage: "link")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(isLinkingNeededExpanded ? 90 : 0))
                                }
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .textCase(nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Viewer")
            .task {
                await loadData()
            }
            .refreshable {
                await loadData()
            }
        }
    }

    // MARK: - Computed Properties

    private var bundlesById: [String: CaptureBundle] {
        Dictionary(uniqueKeysWithValues: captureBundles.map { ($0.id, $0) })
    }

    /// Assets ready to view based on relocalization setting
    private var readyToViewAssets: [(asset: SplatAsset, bundle: CaptureBundle?)] {
        if relocalizationEnabled {
            // Only linked assets when relocalization is ON
            return splatAssets.compactMap { asset -> (SplatAsset, CaptureBundle?)? in
                guard let bundleId = asset.associatedBundleId,
                      let bundle = bundlesById[bundleId] else {
                    return nil
                }
                return (asset, bundle)
            }
        } else {
            // All assets when relocalization is OFF
            return splatAssets.map { asset in
                let bundle = asset.associatedBundleId.flatMap { bundlesById[$0] }
                return (asset, bundle)
            }
        }
    }

    /// Assets that need linking (only relevant when relocalization is ON)
    private var linkingNeededAssets: [SplatAsset] {
        guard relocalizationEnabled else { return [] }
        return splatAssets.filter { asset in
            guard let bundleId = asset.associatedBundleId else { return true }
            return bundlesById[bundleId] == nil
        }
    }

    private var viewerEmptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "cube.transparent")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue.opacity(0.6))
            }

            VStack(spacing: 8) {
                Text("No Splat Assets")
                    .font(.headline)

                Text("Import a trained 3DGS asset in the Library tab to start viewing in AR")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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

// MARK: - Viewer Asset Row

private struct ViewerAssetRow: View {
    let asset: SplatAsset
    let isLinked: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.blue)
                }

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text(asset.name)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    if let gaussianCount = asset.formattedGaussianCount {
                        Label(gaussianCount, systemImage: "circle.grid.3x3")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Link status
                if isLinked {
                    Label("Linked", systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ViewerView()
}

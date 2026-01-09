//
//  LibraryView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import ARKit
import SwiftUI

struct LibraryView: View {
    @State private var capturedBundles: [CaptureBundle] = []
    @State private var splatAssets: [SplatAsset] = []
    @State private var selectedBundle: CaptureBundle?
    @State private var selectedBundleIds = Set<CaptureBundle.ID>()
    @State private var selectedSplatAsset: SplatAsset?
    @State private var showingImportPicker = false
    @State private var libraryErrorMessage: String?
    @State private var isBundlesSectionExpanded = true
    @State private var isSplatAssetsSectionExpanded = true
    @Environment(\.editMode) private var editMode

    var body: some View {
        NavigationStack {
            List(selection: $selectedBundleIds) {
                // Capture Bundles Section
                Section {
                    if isBundlesSectionExpanded {
                        if capturedBundles.isEmpty {
                            LibraryEmptyState(
                                icon: "camera.viewfinder",
                                title: "No Captures",
                                description: "Captured scans will appear here"
                            )
                        } else {
                            ForEach(capturedBundles) { bundle in
                                CaptureBundleRow(bundle: bundle)
                                    .contentShape(Rectangle())
                                    .tag(bundle.id)
                                    .onTapGesture {
                                        guard editMode?.wrappedValue.isEditing != true else { return }
                                        selectedBundle = bundle
                                    }
                            }
                            .onDelete(perform: deleteBundles)
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            isBundlesSectionExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Label("Capture Bundles", systemImage: "photo.stack")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isBundlesSectionExpanded ? 90 : 0))
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                    }
                    .buttonStyle(.plain)
                }

                // Splat Assets Section
                Section {
                    if isSplatAssetsSectionExpanded {
                        if splatAssets.isEmpty {
                            LibraryEmptyState(
                                icon: "cube.transparent",
                                title: "No Splat Assets",
                                description: "Import trained 3DGS assets to view in AR"
                            )
                        } else {
                            ForEach(splatAssets) { asset in
                                SplatAssetRow(asset: asset)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedSplatAsset = asset
                                    }
                            }
                            .onDelete(perform: deleteSplatAssets)
                            .selectionDisabled(true)
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            isSplatAssetsSectionExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Label("Splat Assets", systemImage: "cube.transparent")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isSplatAssetsSectionExpanded ? 90 : 0))
                        }
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: importSplatAsset) {
                            Label("Import Splat Asset", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if editMode?.wrappedValue.isEditing == true {
                        Button(role: .destructive, action: deleteSelectedBundles) {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedBundleIds.isEmpty)
                    }
                }
            }
            .task {
                await loadLibrary()
            }
            .refreshable {
                await loadLibrary()
            }
            .onReceive(NotificationCenter.default.publisher(for: .splatAssetsDidChange)) { _ in
                Task { await loadLibrary() }
            }
            .onChange(of: editMode?.wrappedValue.isEditing ?? false) { _, isEditing in
                if !isEditing {
                    selectedBundleIds.removeAll()
                }
            }
            .sheet(item: $selectedBundle) { bundle in
                BundleDetailView(bundle: bundle, onDismiss: {
                    selectedBundle = nil
                    Task {
                        await loadLibrary()
                    }
                })
            }
            .sheet(item: $selectedSplatAsset) { asset in
                SplatAssetDetailView(
                    asset: asset,
                    bundles: capturedBundles,
                    onUpdate: {
                        Task { await loadLibrary() }
                    }
                )
            }
            .sheet(isPresented: $showingImportPicker) {
                DocumentImportPicker(
                    contentTypes: SplatAssetManager.supportedContentTypes,
                    allowsMultipleSelection: true
                ) { result in
                    showingImportPicker = false
                    handleImportResult(result)
                }
            }
            .alert("Library Error", isPresented: Binding(
                get: { libraryErrorMessage != nil },
                set: { if !$0 { libraryErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(libraryErrorMessage ?? "Unknown error")
            }
        }
    }

    private func loadLibrary() async {
        let bundles = await CaptureBundleManager.shared.listBundlesAsync()
        await MainActor.run {
            capturedBundles = bundles
        }
        let assets = await SplatAssetManager.shared.listAssetsAsync()
        await MainActor.run {
            splatAssets = assets
        }
    }

    private func importSplatAsset() {
        showingImportPicker = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task {
                await importAssets(urls)
            }
        case .failure(let error):
            libraryErrorMessage = error.localizedDescription
        }
    }

    private func importAssets(_ urls: [URL]) async {
        var imported: [SplatAsset] = []
        var errors: [String] = []

        for url in urls {
            do {
                let asset = try SplatAssetManager.shared.importAsset(from: url)
                imported.append(asset)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            await Task.yield()
        }

        splatAssets = (splatAssets + imported).sorted { $0.importedAt > $1.importedAt }
        if !errors.isEmpty {
            libraryErrorMessage = errors.joined(separator: "\n")
        }
    }

    private func deleteBundles(at offsets: IndexSet) {
        for index in offsets {
            let bundle = capturedBundles[index]
            do {
                try CaptureBundleManager.shared.deleteBundle(bundle)
            } catch {
                // Handle error silently for now
            }
        }
        capturedBundles.remove(atOffsets: offsets)
    }

    private func deleteSelectedBundles() {
        let bundlesToDelete = capturedBundles.filter { selectedBundleIds.contains($0.id) }
        for bundle in bundlesToDelete {
            try? CaptureBundleManager.shared.deleteBundle(bundle)
        }
        capturedBundles.removeAll { selectedBundleIds.contains($0.id) }
        selectedBundleIds.removeAll()
    }

    private func deleteSplatAssets(at offsets: IndexSet) {
        for index in offsets {
            let asset = splatAssets[index]
            do {
                try SplatAssetManager.shared.deleteAsset(asset)
            } catch {
                libraryErrorMessage = "Failed to delete \(asset.name): \(error.localizedDescription)"
            }
        }
        splatAssets.remove(atOffsets: offsets)
    }
}

struct CaptureBundleRow: View {
    let bundle: CaptureBundle

    private var hasWorldMap: Bool {
        CaptureBundleManager.shared.hasWorldMap(at: bundle.bundleURL)
    }

    private var relocalizationStatus: (icon: String, color: Color) {
        guard let quality = bundle.manifest.relocalizationQuality else {
            return ("questionmark.circle", .gray)
        }

        if let testResult = quality.lastRelocalizationTestResult {
            if testResult.success {
                return ("checkmark.circle.fill", .green)
            } else {
                return ("xmark.circle.fill", .red)
            }
        }

        if quality.worldMapSaved && quality.mappingStatusReached {
            return ("circle.dashed", .yellow)
        } else if quality.worldMapSaved {
            return ("circle.dashed", .orange)
        }

        return ("xmark.circle", .red)
    }

    var body: some View {
        HStack {
            BundleThumbnailView(
                bundle: bundle,
                size: 60,
                placeholderSystemImage: "camera.viewfinder"
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bundle.manifest.bundleId.prefix(8) + "...")
                        .font(.headline)

                    // Relocalization status indicator
                    Image(systemName: relocalizationStatus.icon)
                        .foregroundStyle(relocalizationStatus.color)
                        .font(.caption)
                }

                Text(bundle.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Label("\(bundle.manifest.captureStats.frameCount)", systemImage: "photo.stack")
                    if bundle.manifest.captureSettings.depthEnabled {
                        Label("\(bundle.manifest.captureStats.depthFrameCount)", systemImage: "cube")
                    }
                    if hasWorldMap {
                        Label("Map", systemImage: "globe.americas.fill")
                            .foregroundStyle(.blue)
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

                if let gaussianCount = asset.formattedGaussianCount {
                    Text("Gaussians: \(gaussianCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Gaussians: n/a")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let bundleId = asset.associatedBundleId {
                    Text("Linked: \(bundleId.prefix(8))...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not linked")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct SplatAssetDetailView: View {
    let asset: SplatAsset
    let bundles: [CaptureBundle]
    let onUpdate: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentAsset: SplatAsset
    @State private var selectedBundleId: String?
    @State private var updateErrorMessage: String?

    init(asset: SplatAsset, bundles: [CaptureBundle], onUpdate: @escaping () -> Void) {
        self.asset = asset
        self.bundles = bundles
        self.onUpdate = onUpdate
        _currentAsset = State(initialValue: asset)
        _selectedBundleId = State(initialValue: asset.associatedBundleId)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Asset Info") {
                    LabeledContent("Name", value: currentAsset.name)
                    LabeledContent("Format", value: currentAsset.fileExtension.uppercased())
                    LabeledContent("File Size", value: currentAsset.formattedFileSize)
                    LabeledContent("Imported", value: currentAsset.importedAt.formatted(date: .abbreviated, time: .shortened))
                    if let gaussianCount = currentAsset.formattedGaussianCount {
                        LabeledContent("Gaussians", value: gaussianCount)
                    } else {
                        LabeledContent("Gaussians", value: "n/a")
                    }
                }

                Section("Linked Capture Bundle") {
                    if bundles.isEmpty {
                        Text("No captures available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Linked Bundle", selection: $selectedBundleId) {
                            Text("Not linked").tag(String?.none)
                            ForEach(bundles) { bundle in
                                Text(bundle.manifest.bundleId.prefix(8) + "...")
                                    .tag(Optional(bundle.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .navigationTitle("Splat Asset")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: selectedBundleId, initial: false) { _, newValue in
                updateAssociation(to: newValue)
            }
            .alert("Update Failed", isPresented: Binding(
                get: { updateErrorMessage != nil },
                set: { if !$0 { updateErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(updateErrorMessage ?? "Unknown error")
            }
        }
    }

    private func updateAssociation(to bundleId: String?) {
        let updated = currentAsset.updatingAssociation(bundleId)

        Task {
            do {
                try SplatAssetManager.shared.updateAsset(updated)
                await MainActor.run {
                    currentAsset = updated
                    onUpdate()
                }
            } catch {
                await MainActor.run {
                    updateErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Bundle Detail View

struct BundleDetailView: View {
    let bundle: CaptureBundle
    let onDismiss: () -> Void

    @State private var isPreparingExport = false
    @State private var exportURL: URL?
    @State private var showingExportPicker = false
    @State private var showingShareSheet = false
    @State private var showingExportError = false
    @State private var exportErrorMessage = ""
    @State private var bundleSize: Int64 = 0

    private var hasWorldMap: Bool {
        CaptureBundleManager.shared.hasWorldMap(at: bundle.bundleURL)
    }

    private enum ExportDestination {
        case files
        case share
    }

    var body: some View {
        NavigationStack {
            List {
                // Capture Info Section
                Section("Capture Info") {
                    LabeledContent("Bundle ID", value: String(bundle.manifest.bundleId.prefix(8)) + "...")
                    LabeledContent("Created", value: bundle.manifest.createdAt.formatted())
                }

                // Frame Statistics Section
                Section("Frame Statistics") {
                    LabeledContent("Total Frames", value: "\(bundle.manifest.captureStats.frameCount)")
                    LabeledContent("Depth Frames", value: "\(bundle.manifest.captureStats.depthFrameCount)")
                    LabeledContent("Storage Size", value: formatBytes(bundleSize))
                }

                // World Map Section
                Section("World Map") {
                    HStack {
                        Text("Status")
                        Spacer()
                        if hasWorldMap {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Available", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Export Section
                Section {
                    Button {
                        prepareExport(for: .files)
                    } label: {
                        Label("Export Bundle to Files", systemImage: "folder")
                    }
                    .disabled(isPreparingExport)

                    Button {
                        prepareExport(for: .share)
                    } label: {
                        Label("Share Bundle (AirDrop)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isPreparingExport)

                    if isPreparingExport {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Preparing export...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text("Exports the full capture bundle folder for offline training.")
                }
            }
            .navigationTitle("Bundle Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
            .task {
                bundleSize = await CaptureBundleManager.shared.calculateDirectorySizeAsync(at: bundle.bundleURL)
            }
            .sheet(isPresented: $showingExportPicker) {
                if let exportURL {
                    DocumentExportPicker(urls: [exportURL]) { _ in
                        cleanupExport()
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let exportURL {
                    ActivityShareSheet(items: [exportURL]) { _ in
                        cleanupExport()
                    }
                }
            }
            .alert("Export Failed", isPresented: $showingExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func prepareExport(for destination: ExportDestination) {
        guard !isPreparingExport else { return }
        isPreparingExport = true

        Task {
            do {
                let url = try await CaptureBundleManager.shared.createExportFolder(for: bundle)
                await MainActor.run {
                    exportURL = url
                    isPreparingExport = false
                    switch destination {
                    case .files:
                        showingExportPicker = true
                    case .share:
                        showingShareSheet = true
                    }
                }
            } catch {
                await MainActor.run {
                    isPreparingExport = false
                    exportErrorMessage = error.localizedDescription
                    showingExportError = true
                }
            }
        }
    }

    private func cleanupExport() {
        exportURL = nil
    }
}

// MARK: - Library Empty State

private struct LibraryEmptyState: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}

#Preview {
    LibraryView()
}

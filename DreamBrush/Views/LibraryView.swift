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
    @Environment(\.editMode) private var editMode

    var body: some View {
        NavigationStack {
            List(selection: $selectedBundleIds) {
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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedSplatAsset = asset
                                }
                        }
                        .onDelete(perform: deleteSplatAssets)
                        .selectionDisabled(true)
                    }
                }
            }
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
    @State private var loadTestState: LoadTestState = .idle
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

                Section("Load Test") {
                    Button {
                        runLoadTest()
                    } label: {
                        Label("Run Load Test", systemImage: "checkmark.seal")
                    }

                    loadTestStatusView
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

    @ViewBuilder
    private var loadTestStatusView: some View {
        switch loadTestState {
        case .idle:
            Text("Validate that the PLY header parses correctly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            HStack {
                ProgressView()
                Text("Testing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
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

    private func runLoadTest() {
        loadTestState = .running

        Task {
            let result = SplatAssetManager.shared.validateAsset(currentAsset)

            if result.success {
                loadTestState = .success(result.details)
                if result.gaussianCount != nil, result.gaussianCount != currentAsset.gaussianCount {
                    let updated = currentAsset.updatingGaussianCount(result.gaussianCount)
                    do {
                        try SplatAssetManager.shared.updateAsset(updated)
                        currentAsset = updated
                        onUpdate()
                    } catch {
                        updateErrorMessage = error.localizedDescription
                    }
                }
            } else {
                loadTestState = .failure(result.details)
            }
        }
    }

    private enum LoadTestState {
        case idle
        case running
        case success(String)
        case failure(String)
    }
}

// MARK: - Bundle Detail View

struct BundleDetailView: View {
    let bundle: CaptureBundle
    let onDismiss: () -> Void

    @State private var sessionManager = CaptureSessionManager()
    @State private var isTestingRelocalization = false
    @State private var testResult: RelocalizationTestResult?
    @State private var showingTestView = false
    @State private var isPreparingExport = false
    @State private var exportURL: URL?
    @State private var showingExportPicker = false
    @State private var showingShareSheet = false
    @State private var showingExportError = false
    @State private var exportErrorMessage = ""

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
                    LabeledContent("Duration", value: formatDuration(bundle.manifest.captureStats.durationSeconds))
                    LabeledContent("Device", value: bundle.manifest.deviceModel)
                }

                // Frame Statistics Section
                Section("Frame Statistics") {
                    LabeledContent("Total Frames", value: "\(bundle.manifest.captureStats.frameCount)")
                    LabeledContent("Keyframes", value: "\(bundle.manifest.captureStats.keyframeCount)")
                    LabeledContent("Depth Frames", value: "\(bundle.manifest.captureStats.depthFrameCount)")
                    LabeledContent("Storage Size", value: formatBytes(bundle.manifest.captureStats.estimatedSizeBytes))
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

                // Relocalization Quality Section
                Section("Relocalization Quality") {
                    if let quality = bundle.manifest.relocalizationQuality {
                        RelocalizationQualityView(quality: quality)
                    } else {
                        Text("No relocalization data available")
                            .foregroundStyle(.secondary)
                    }

                    // World map status
                    HStack {
                        Text("World Map")
                        Spacer()
                        if hasWorldMap {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Available", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                    }

                    // Last test result
                    if let result = bundle.manifest.relocalizationQuality?.lastRelocalizationTestResult {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Last Test")
                                Spacer()
                                if result.success {
                                    Label("Passed", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Label("Failed", systemImage: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                            if let time = result.timeToRelocalize {
                                Text("Relocalized in \(String(format: "%.1f", time))s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let notes = result.notes {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Test Relocalization Section
                if hasWorldMap {
                    Section {
                        Button(action: { showingTestView = true }) {
                            HStack {
                                Image(systemName: "location.viewfinder")
                                Text("Test Relocalization")
                            }
                        }
                        .disabled(isTestingRelocalization)
                    } footer: {
                        Text("Walk back to the scanned area and test if the app can relocalize to the saved world map.")
                    }
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
            .fullScreenCover(isPresented: $showingTestView) {
                RelocalizationTestView(bundle: bundle, onComplete: { result in
                    testResult = result
                    showingTestView = false
                    // Reload the bundle to get updated test result
                    onDismiss()
                })
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

    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
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

// MARK: - Relocalization Quality View

struct RelocalizationQualityView: View {
    let quality: RelocalizationQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Overall quality score
            HStack {
                Text("Overall Quality")
                Spacer()
                Text(quality.qualityAssessment)
                    .foregroundStyle(qualityColor)
                    .fontWeight(.medium)
            }

            // Quality metrics
            QualityMetricRow(
                label: "Good Tracking",
                value: "\(Int(quality.goodTrackingPercentage * 100))%",
                icon: "location.fill",
                isGood: quality.goodTrackingPercentage > 0.7
            )

            QualityMetricRow(
                label: "Mapping Status",
                value: quality.mappingStatusReached ? "Reached" : "Not Reached",
                icon: "map.fill",
                isGood: quality.mappingStatusReached
            )

            QualityMetricRow(
                label: "Depth Confidence",
                value: "\(Int(quality.averageDepthConfidence * 100))%",
                icon: "cube.fill",
                isGood: quality.averageDepthConfidence > 0.5
            )

            QualityMetricRow(
                label: "World Map",
                value: quality.worldMapSaved ? "Saved" : "Not Saved",
                icon: "globe.americas.fill",
                isGood: quality.worldMapSaved
            )
        }
    }

    private var qualityColor: Color {
        switch quality.qualityAssessment {
        case "Excellent": return .green
        case "Good": return .blue
        case "Fair": return .orange
        default: return .red
        }
    }
}

struct QualityMetricRow: View {
    let label: String
    let value: String
    let icon: String
    let isGood: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(isGood ? .green : .orange)
                .frame(width: 20)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(isGood ? .primary : .secondary)
        }
    }
}

// MARK: - Relocalization Test View

struct RelocalizationTestView: View {
    let bundle: CaptureBundle
    let onComplete: (RelocalizationTestResult?) -> Void

    @State private var sessionManager = CaptureSessionManager()
    @State private var testStarted = false
    @State private var testComplete = false
    @State private var result: RelocalizationTestResult?

    var body: some View {
        ZStack {
            // AR Camera Preview
            ARViewContainer(session: sessionManager.session ?? ARSession())
                .ignoresSafeArea()

            // Overlay
            VStack {
                // Top status
                VStack(spacing: 8) {
                    Text(sessionManager.relocalizationTestStatus.isEmpty ? "Preparing..." : sessionManager.relocalizationTestStatus)
                        .font(.headline)
                        .foregroundStyle(.white)

                    // Tracking status
                    HStack(spacing: 16) {
                        StatusPill(
                            title: "Tracking",
                            value: sessionManager.trackingState.displayName,
                            color: sessionManager.trackingState.color
                        )
                        StatusPill(
                            title: "Mapping",
                            value: sessionManager.worldMappingStatus.displayName,
                            color: sessionManager.worldMappingStatus.color
                        )
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding()

                Spacer()

                // Instructions
                VStack(spacing: 16) {
                    if !testStarted {
                        Text("Move to the area where you captured the scan")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)

                        Button("Start Test") {
                            startTest()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if testComplete {
                        if let result = result {
                            VStack(spacing: 8) {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundStyle(result.success ? .green : .red)

                                Text(result.success ? "Relocalization Successful!" : "Relocalization Failed")
                                    .font(.headline)
                                    .foregroundStyle(.white)

                                if let notes = result.notes {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }

                            Button("Done") {
                                onComplete(result)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)

                        Text("Walk around the scanned area...")
                            .font(.body)
                            .foregroundStyle(.white)

                        Button("Cancel") {
                            sessionManager.cancelRelocalizationTest()
                            onComplete(nil)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding()
            }

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button(action: { onComplete(nil) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .onAppear {
            setupSession()
        }
        .onDisappear {
            sessionManager.pauseSession()
        }
    }

    private func setupSession() {
        _ = sessionManager.createSession()
        sessionManager.startSession()
    }

    private func startTest() {
        testStarted = true

        Task {
            do {
                let testResult = try await sessionManager.testRelocalization(for: bundle)
                result = testResult
                testComplete = true

                // Save the test result to the bundle
                saveTestResult(testResult)
            } catch {
                result = RelocalizationTestResult(success: false, notes: error.localizedDescription)
                testComplete = true
            }
        }
    }

    private func saveTestResult(_ testResult: RelocalizationTestResult) {
        // Try to update the manifest with the test result
        var updatedBundle = bundle
        do {
            try CaptureBundleManager.shared.updateManifest(for: &updatedBundle) { manifest in
                if manifest.relocalizationQuality != nil {
                    manifest.relocalizationQuality?.lastRelocalizationTestDate = Date()
                    manifest.relocalizationQuality?.lastRelocalizationTestResult = testResult
                }
            }
        } catch {
            // Silently fail - test result won't be persisted but that's okay
        }
    }
}

#Preview {
    LibraryView()
}

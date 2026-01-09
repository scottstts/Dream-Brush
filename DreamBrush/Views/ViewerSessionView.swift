//
//  ViewerSessionView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import ARKit
import Darwin
import SwiftUI
import UIKit
import simd

struct ViewerSessionView: View {
    let asset: SplatAsset
    let bundle: CaptureBundle?
    let relocalizationEnabled: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(TabBarVisibilityManager.self) private var tabBarVisibility
    @State private var sessionManager = ViewerSessionManager()
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var renderLoadError: String?
    @State private var splatCount: Int?
    @State private var frameStats: FrameStats?
    @State private var memoryUsageMB: Double?
    @State private var showPerformanceHUD = false
    @State private var qualityPreset: QualityPreset = .balanced
    @State private var autoSelectionCompleted = false
    @State private var manualPresetOverride = false
    @State private var autoSelecting = false
    @State private var showRelocIndicator = true
    @State private var relocIndicatorTask: Task<Void, Never>?
    @State private var wasRendering = false
    @State private var wasIdleTimerDisabled: Bool?

    var body: some View {
        ZStack {
            ViewerARViewContainer(
                session: sessionManager.session ?? ARSession(),
                splatURL: asset.fileURL,
                renderTransform: sessionManager.alignmentTransform,
                shouldRender: effectiveShouldRender,
                showCameraFeed: shouldShowCameraFeed,
                renderMode: .aligned,
                preferredFramesPerSecond: qualityPreset.targetFPS,
                renderScale: qualityPreset.renderScale,
                maxSplats: qualityPreset.maxSplats(total: asset.gaussianCount),
                renderStride: qualityPreset.renderStride
            ) { error in
                renderLoadError = error
            } onStatsUpdate: { count in
                splatCount = count
            } onFrameStatsUpdate: { stats in
                frameStats = stats
            }
            .ignoresSafeArea()

            VStack {
                Spacer()

                // Relocalization indicator (conditionally shown)
                if shouldShowRelocIndicator {
                    bottomOverlay
                        .padding(.bottom, 24)
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // Performance HUD at top right, below toolbar
            if showPerformanceHUD {
                VStack {
                    performanceHUD
                        .padding(.top, 60)
                        .padding(.trailing, 12)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onChange(of: qualityPreset) { _, _ in
            if !autoSelecting {
                manualPresetOverride = true
            }
        }
        .onChange(of: sessionManager.shouldRender) { oldValue, newValue in
            handleRenderStateChange(wasRendering: oldValue, isRendering: newValue)
        }
        .onAppear {
            tabBarVisibility.isHidden = true
            if wasIdleTimerDisabled == nil {
                wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            tabBarVisibility.isHidden = false
            sessionManager.pauseSession()
            relocIndicatorTask?.cancel()
            if let wasIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
            }
        }
        .task {
            startSessionIfNeeded()
        }
        .task {
            await updateMemoryLoop()
        }
        .task {
            await autoSelectQualityIfNeeded()
        }
        .alert("Viewer Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Splat Load Failed", isPresented: Binding(
            get: { renderLoadError != nil },
            set: { if !$0 { renderLoadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renderLoadError ?? "Unknown error")
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Quality", selection: $qualityPreset) {
                        ForEach(QualityPreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Toggle("Performance HUD", isOn: $showPerformanceHUD)
                } label: {
                    Label("Performance", systemImage: "speedometer")
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showRelocIndicator)
    }

    // MARK: - Relocalization Indicator Visibility

    private var shouldShowRelocIndicator: Bool {
        // Never show when relocalization is disabled
        guard relocalizationEnabled else { return false }
        return showRelocIndicator
    }

    private var shouldShowCameraFeed: Bool {
        relocalizationEnabled && !sessionManager.shouldRender
    }

    private func handleRenderStateChange(wasRendering: Bool, isRendering: Bool) {
        relocIndicatorTask?.cancel()

        if isRendering && !wasRendering {
            // Just started rendering - show indicator briefly then hide
            showRelocIndicator = true
            relocIndicatorTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                showRelocIndicator = false
            }
        } else if !isRendering && wasRendering {
            // Rendering stopped (relocalization broke) - show indicator
            showRelocIndicator = true
        } else if isRendering {
            // Still rendering - start hide timer if showing
            if showRelocIndicator {
                relocIndicatorTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    showRelocIndicator = false
                }
            }
        }

        self.wasRendering = isRendering
    }

    @ViewBuilder
    private var bottomOverlay: some View {
        if sessionManager.shouldRender {
            VStack(spacing: 8) {
                Label("Aligned", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                if let splatCount {
                    Text("\(splatCount) splats rendering")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        } else if sessionManager.mismatchDetected {
            VStack(spacing: 12) {
                Label("Not Aligned", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                Text(sessionManager.relocalizationMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)

                Button("Retry") {
                    sessionManager.retryRelocalization()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)

                Text("Searching for alignment...")
                    .font(.subheadline)
                    .foregroundStyle(.white)

                Text("\(Int(sessionManager.relocalizationElapsed))s")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private var performanceHUD: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let frameStats {
                Text(String(format: "%.1f fps (%.1f ms)", frameStats.fps, frameStats.frameTimeMs))
                    .font(.caption2)
                    .foregroundStyle(.white)
            }

            Text("Quality: \(qualityPreset.title)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))

            if let maxSplats = qualityPreset.maxSplats(total: asset.gaussianCount) {
                Text("Max splats: \(maxSplats)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
            }

            Text("Thermal: \(thermalStateLabel)")
                .font(.caption2)
                .foregroundStyle(thermalStateColor)

            if let memoryUsageMB {
                Text(String(format: "Memory: %.1f MB", memoryUsageMB))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }

    private var thermalStateLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalStateColor: Color {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private var effectiveShouldRender: Bool {
        return sessionManager.shouldRender
    }

    private func startSessionIfNeeded() {
        guard !sessionManager.isSessionRunning else { return }

        // Handle optional bundle - when nil, render without alignment
        guard let bundle else {
            // Start session without world map (no relocalization)
            do {
                try sessionManager.startSessionWithoutBundle(
                    modelToCapture: modelToCaptureTransform()
                )
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
            return
        }

        do {
            try sessionManager.startSession(
                for: bundle,
                modelToCapture: modelToCaptureTransform(),
                relocalizationEnabled: relocalizationEnabled
            )
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func modelToCaptureTransform() -> simd_float4x4? {
        guard let transform = asset.modelToCaptureTransform else { return nil }
        return ViewerSessionManager.matrix(from: transform, layout: asset.modelToCaptureLayout ?? "row_major")
    }

    private func updateMemoryLoop() async {
        while !Task.isCancelled {
            memoryUsageMB = currentMemoryUsageMB()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func autoSelectQualityIfNeeded() async {
        guard !autoSelectionCompleted, !manualPresetOverride else { return }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if manualPresetOverride { return }
            if let fps = frameStats?.fps {
                let selected: QualityPreset
                if fps < 6 {
                    selected = .fast
                } else if fps < 14 {
                    selected = .balanced
                } else {
                    selected = .quality
                }

                if selected != qualityPreset {
                    await MainActor.run {
                        autoSelecting = true
                        qualityPreset = selected
                        autoSelecting = false
                    }
                }

                autoSelectionCompleted = true
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        autoSelectionCompleted = true
    }

    private func currentMemoryUsageMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024 * 1024)
    }

    enum QualityPreset: String, CaseIterable {
        case fast
        case balanced
        case quality

        var title: String {
            switch self {
            case .fast: return "Fast"
            case .balanced: return "Balanced"
            case .quality: return "Quality"
            }
        }

        var targetFPS: Int {
            switch self {
            case .fast: return 15
            case .balanced: return 24
            case .quality: return 30
            }
        }

        var renderScale: CGFloat {
            switch self {
            case .fast: return 1.0
            case .balanced: return 1.0
            case .quality: return 1.0
            }
        }

        var renderStride: Int {
            switch self {
            case .fast: return 3
            case .balanced: return 2
            case .quality: return 1
            }
        }

        func maxSplats(total: Int?) -> Int? {
            guard let total, total > 0 else {
                switch self {
                case .fast: return 5_000
                case .balanced: return 10_000
                case .quality: return nil
                }
            }
            switch self {
            case .fast:
                return min(20_000, max(5_000, total / 5))
            case .balanced:
                return min(60_000, max(10_000, total / 2))
            case .quality:
                return nil
            }
        }
    }
}

//
//  ViewerSessionView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import ARKit
import Darwin
import SwiftUI
import simd

struct ViewerSessionView: View {
    let asset: SplatAsset
    let bundle: CaptureBundle

    @Environment(\.dismiss) private var dismiss
    @State private var sessionManager = ViewerSessionManager()
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var renderLoadError: String?
    @State private var splatCount: Int?
    @State private var frameStats: FrameStats?
    @State private var memoryUsageMB: Double?
    @State private var showPerformanceHUD = true
    @State private var qualityPreset: QualityPreset = .balanced
    @State private var isUserInteracting = false
    @State private var interactionTask: Task<Void, Never>?
#if DEBUG
    @State private var renderMode: ViewerARViewContainer.RenderMode = .aligned
#endif

    var body: some View {
        ZStack {
            ViewerARViewContainer(
                session: sessionManager.session ?? ARSession(),
                splatURL: asset.fileURL,
                renderTransform: sessionManager.alignmentTransform,
                shouldRender: effectiveShouldRender,
                renderMode: currentRenderMode,
                preferredFramesPerSecond: qualityPreset.targetFPS,
                renderScale: qualityPreset.renderScale,
                maxSplats: qualityPreset.maxSplats(total: asset.gaussianCount)
            ) { error in
                renderLoadError = error
            } onStatsUpdate: { count in
                splatCount = count
            } onFrameStatsUpdate: { stats in
                frameStats = stats
            }
            .ignoresSafeArea()

            VStack {
                topStatusBar
                    .padding(.top, 8)

                Spacer()

                bottomOverlay
                    .padding(.bottom, 24)
            }
            .padding(.horizontal)

            if showPerformanceHUD {
                performanceHUD
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    noteUserInteraction()
                }
                .onEnded { _ in
                    noteUserInteraction()
                }
        )
        .onDisappear {
            sessionManager.pauseSession()
            interactionTask?.cancel()
        }
        .task {
            startSessionIfNeeded()
        }
        .task {
            await updateMemoryLoop()
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
#if DEBUG
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(ViewerARViewContainer.RenderMode.allCases, id: \.self) { mode in
                        Button(mode.title) {
                            renderMode = mode
                        }
                    }
                } label: {
                    Label("Debug Render", systemImage: "ladybug")
                }
            }
#endif
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
    }

    private var topStatusBar: some View {
        HStack(spacing: 12) {
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

            let relocalization = relocalizationStatus
            StatusPill(
                title: "Reloc",
                value: relocalization.title,
                color: relocalization.color
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var bottomOverlay: some View {
        if sessionManager.shouldRender {
            VStack(spacing: 8) {
                Label("Rendering enabled", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                if let summary = alignmentSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }

                if let anchorError = anchorErrorSummary {
                    Text(anchorError)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }

                if let splatCount {
                    Text("Splats: \(splatCount)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }

#if DEBUG
                if renderMode != .aligned {
                    Text("Debug mode: \(renderMode.title)")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
#endif
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        } else if sessionManager.mismatchDetected {
            VStack(spacing: 12) {
                Label("Not relocalized", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                Text(sessionManager.relocalizationMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)

                Button("Retry Relocalization") {
                    sessionManager.retryRelocalization()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)

                Text(sessionManager.relocalizationMessage)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Elapsed: \(Int(sessionManager.relocalizationElapsed))s")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
    }

    private var relocalizationStatus: (title: String, color: Color) {
        if sessionManager.shouldRender {
            return ("Aligned", .green)
        }
        if sessionManager.mismatchDetected {
            return ("Mismatch", .red)
        }
        return ("Searching", .orange)
    }

    private var alignmentSummary: String? {
        guard let transform = sessionManager.alignmentTransform else { return nil }
        let t = transform.translation
        return String(format: "Alignment: (%.2f, %.2f, %.2f)m", t.x, t.y, t.z)
    }

    private var anchorErrorSummary: String? {
        guard let positionError = sessionManager.anchorPositionError,
              let angleError = sessionManager.anchorAngleError else { return nil }
        return String(format: "Anchor error: %.2fm, %.1fdeg", positionError, angleError * 180 / .pi)
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
        if isUserInteracting {
            return false
        }
#if DEBUG
        if renderMode != .aligned {
            return true
        }
#endif
        return sessionManager.shouldRender
    }

    private var currentRenderMode: ViewerARViewContainer.RenderMode {
#if DEBUG
        return renderMode
#else
        return .aligned
#endif
    }

    private func startSessionIfNeeded() {
        guard !sessionManager.isSessionRunning else { return }
        do {
            try sessionManager.startSession(
                for: bundle,
                modelToCapture: modelToCaptureTransform()
            )
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func modelToCaptureTransform() -> simd_float4x4? {
        guard let transform = asset.modelToCaptureTransform else { return nil }
        guard transform.count == 4, transform.allSatisfy({ $0.count == 4 }) else { return nil }
        let c0 = SIMD4<Float>(transform[0][0], transform[0][1], transform[0][2], transform[0][3])
        let c1 = SIMD4<Float>(transform[1][0], transform[1][1], transform[1][2], transform[1][3])
        let c2 = SIMD4<Float>(transform[2][0], transform[2][1], transform[2][2], transform[2][3])
        let c3 = SIMD4<Float>(transform[3][0], transform[3][1], transform[3][2], transform[3][3])
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    private func updateMemoryLoop() async {
        while !Task.isCancelled {
            memoryUsageMB = currentMemoryUsageMB()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func noteUserInteraction() {
        isUserInteracting = true
        interactionTask?.cancel()
        interactionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            isUserInteracting = false
        }
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

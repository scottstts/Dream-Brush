//
//  ViewerARViewContainer.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import ARKit
import Metal
import MetalKit
import MetalSplatter
import QuartzCore
import SwiftUI
import UIKit
import simd

struct ViewerARViewContainer: UIViewRepresentable {
    enum RenderMode: String, CaseIterable {
        case aligned
        case cameraLocked
        case identity

        var title: String {
            switch self {
            case .aligned: return "Aligned"
            case .cameraLocked: return "Camera (1m forward)"
            case .identity: return "Identity"
            }
        }
    }

    let session: ARSession
    let splatURL: URL?
    let renderTransform: simd_float4x4?
    let shouldRender: Bool
    let showCameraFeed: Bool
    let renderMode: RenderMode
    let preferredFramesPerSecond: Int
    let renderScale: CGFloat
    let maxSplats: Int?
    let renderStride: Int
    let onLoadError: (String) -> Void
    let onStatsUpdate: (Int) -> Void
    let onFrameStatsUpdate: (FrameStats) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ViewerARContainerView {
        let container = ViewerARContainerView()
        container.arView.session = session

        #if DEBUG
        container.arView.debugOptions = [.showFeaturePoints]
        #endif

        context.coordinator.configure(
            metalView: container.metalView,
            session: session,
            splatURL: splatURL,
            onError: onLoadError,
            onStatsUpdate: onStatsUpdate,
            onFrameStatsUpdate: onFrameStatsUpdate
        )
        context.coordinator.updatePerformance(
            preferredFramesPerSecond: preferredFramesPerSecond,
            renderScale: renderScale,
            maxSplats: maxSplats,
            renderStride: renderStride
        )
        context.coordinator.updateSplatURL(splatURL)
        context.coordinator.updateRenderState(
            shouldRender: shouldRender,
            renderTransform: renderTransform,
            renderMode: renderMode
        )
        container.setCameraFeedVisible(showCameraFeed)

        return container
    }

    func updateUIView(_ uiView: ViewerARContainerView, context: Context) {
        if uiView.arView.session !== session {
            uiView.arView.session = session
        }

        context.coordinator.updateRenderState(
            shouldRender: shouldRender,
            renderTransform: renderTransform,
            renderMode: renderMode
        )

        context.coordinator.updateSession(session)
        context.coordinator.updateCallbacks(
            onError: onLoadError,
            onStatsUpdate: onStatsUpdate,
            onFrameStatsUpdate: onFrameStatsUpdate
        )
        context.coordinator.updatePerformance(
            preferredFramesPerSecond: preferredFramesPerSecond,
            renderScale: renderScale,
            maxSplats: maxSplats,
            renderStride: renderStride
        )
        context.coordinator.updateSplatURL(splatURL)
        uiView.setCameraFeedVisible(showCameraFeed)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var splatRenderer: SplatRenderer?
        private var currentSplatKey: String?
        private let inFlightSemaphore = DispatchSemaphore(value: 3)

        private weak var metalView: MTKView?
        private weak var session: ARSession?
        private var shouldRender = false
        private var renderTransform = matrix_identity_float4x4
        private var renderMode: RenderMode = .aligned
        private var preferredFramesPerSecond = 60
        private var renderScale: CGFloat = 1
        private var maxSplats: Int?
        private var renderStride: Int = 1
        private var onError: ((String) -> Void)?
        private var onStatsUpdate: ((Int) -> Void)?
        private var onFrameStatsUpdate: ((FrameStats) -> Void)?
        private var lastFrameTimestamp: CFTimeInterval?
        private var lastStatsPublishTimestamp: CFTimeInterval?
        private var lastRenderTimestamp: CFTimeInterval?
        private var renderInterval: CFTimeInterval = 1.0 / 30.0
        private var splatLoadToken = UUID()
        private var renderFrameIndex: UInt = 0

        func configure(
            metalView: MTKView,
            session: ARSession,
            splatURL: URL?,
            onError: @escaping (String) -> Void,
            onStatsUpdate: @escaping (Int) -> Void,
            onFrameStatsUpdate: @escaping (FrameStats) -> Void
        ) {
            self.metalView = metalView
            self.session = session
            updateCallbacks(
                onError: onError,
                onStatsUpdate: onStatsUpdate,
                onFrameStatsUpdate: onFrameStatsUpdate
            )

            if device == nil {
                device = metalView.device ?? MTLCreateSystemDefaultDevice()
            }

            guard let device else {
                onError("Metal device unavailable")
                return
            }

            if commandQueue == nil {
                commandQueue = device.makeCommandQueue()
            }

            metalView.device = device
            metalView.delegate = self
            metalView.isPaused = false
            metalView.enableSetNeedsDisplay = false
            metalView.colorPixelFormat = .bgra8Unorm_srgb
            metalView.depthStencilPixelFormat = .depth32Float_stencil8
            metalView.sampleCount = 1
            metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            metalView.isOpaque = false
            metalView.backgroundColor = .clear
            metalView.framebufferOnly = true
            metalView.autoResizeDrawable = true

            updateSplatURL(splatURL)
        }

        func updateSession(_ session: ARSession) {
            if self.session !== session {
                self.session = session
            }
        }

        func updateSplatURL(_ splatURL: URL?) {
            guard let splatURL else {
                splatRenderer = nil
                currentSplatKey = nil
                DispatchQueue.main.async {
                    self.onStatsUpdate?(0)
                }
                return
            }

            let key = "\(splatURL.path)|\(maxSplats ?? -1)"
            guard currentSplatKey != key else { return }
            currentSplatKey = key
            let loadToken = UUID()
            splatLoadToken = loadToken
            let maxSplats = self.maxSplats

            guard let device else { return }
            if commandQueue == nil {
                commandQueue = device.makeCommandQueue()
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let resolvedURL = self.resolveSplatURL(for: splatURL, maxSplats: maxSplats)

                do {
                    let renderer = try SplatRenderer(
                        device: device,
                        colorFormat: .bgra8Unorm_srgb,
                        depthFormat: .depth32Float_stencil8,
                        stencilFormat: .depth32Float_stencil8,
                        sampleCount: 1,
                        maxViewCount: 1,
                        maxSimultaneousRenders: 3
                    )
                    try renderer.readPLY(from: resolvedURL)
                    let count = renderer.splatCount
                    DispatchQueue.main.async {
                        guard self.splatLoadToken == loadToken, self.currentSplatKey == key else { return }
                        self.splatRenderer = renderer
                        self.onStatsUpdate?(count)
                        if count == 0 {
                            self.onError?("Loaded splat file but found 0 points")
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    if message.localizedCaseInsensitiveContains("obj_info") {
                        do {
                            let sanitized = try SplatAssetManager.shared.sanitizeObjInfoLinesIfNeeded(at: splatURL)
                            if sanitized {
                                let retry = try SplatRenderer(
                                    device: device,
                                    colorFormat: .bgra8Unorm_srgb,
                                    depthFormat: .depth32Float_stencil8,
                                    stencilFormat: .depth32Float_stencil8,
                                    sampleCount: 1,
                                    maxViewCount: 1,
                                    maxSimultaneousRenders: 3
                                )
                                try retry.readPLY(from: splatURL)
                                let count = retry.splatCount
                                DispatchQueue.main.async {
                                    guard self.splatLoadToken == loadToken, self.currentSplatKey == key else { return }
                                    self.splatRenderer = retry
                                    self.onStatsUpdate?(count)
                                }
                                return
                            }
                        } catch {
                            DispatchQueue.main.async {
                                guard self.splatLoadToken == loadToken, self.currentSplatKey == key else { return }
                                self.onError?("Failed to sanitize splat: \(error.localizedDescription)")
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        guard self.splatLoadToken == loadToken, self.currentSplatKey == key else { return }
                        self.splatRenderer = nil
                        self.onError?("Failed to load splat: \(message)")
                    }
                }
            }
        }

        func updateRenderState(shouldRender: Bool, renderTransform: simd_float4x4?, renderMode: RenderMode) {
            self.shouldRender = shouldRender
            self.renderTransform = renderTransform ?? matrix_identity_float4x4
            self.renderMode = renderMode
        }

        func updateCallbacks(
            onError: @escaping (String) -> Void,
            onStatsUpdate: @escaping (Int) -> Void,
            onFrameStatsUpdate: @escaping (FrameStats) -> Void
        ) {
            self.onError = onError
            self.onStatsUpdate = onStatsUpdate
            self.onFrameStatsUpdate = onFrameStatsUpdate
        }

        func updatePerformance(preferredFramesPerSecond: Int, renderScale: CGFloat, maxSplats: Int?, renderStride: Int) {
            self.preferredFramesPerSecond = preferredFramesPerSecond
            let sanitizedScale: CGFloat
            if !renderScale.isFinite {
                sanitizedScale = 1.0
            } else {
                sanitizedScale = renderScale
            }
            self.renderScale = max(0.25, min(sanitizedScale, 1.0))
            self.maxSplats = maxSplats
            self.renderStride = max(1, renderStride)
            guard let metalView else { return }
            let clampedFPS = max(5, min(preferredFramesPerSecond, 60))
            metalView.preferredFramesPerSecond = clampedFPS
            metalView.autoResizeDrawable = true
            renderInterval = 1.0 / Double(clampedFPS)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No-op; we read size during draw.
        }

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            if let lastRenderTimestamp, now - lastRenderTimestamp < renderInterval {
                return
            }
            lastRenderTimestamp = now

            renderFrameIndex &+= 1
            if renderStride > 1, renderFrameIndex % UInt(renderStride) != 0 {
                return
            }

            // Never block the main thread on GPU work; drop the frame if we're behind.
            guard inFlightSemaphore.wait(timeout: .now()) == .success else {
                return
            }

            guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
                inFlightSemaphore.signal()
                return
            }

            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }

            updateFrameStats()

            guard let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                if let drawable = view.currentDrawable {
                    commandBuffer.present(drawable)
                }
                commandBuffer.commit()
                return
            }

            if shouldRender, let renderer = splatRenderer, let frame = session?.currentFrame {
                let drawableWidth = view.drawableSize.width
                let drawableHeight = view.drawableSize.height
                guard drawableWidth.isFinite,
                      drawableHeight.isFinite,
                      drawableWidth > 0,
                      drawableHeight > 0 else {
                    renderEncoder.endEncoding()
                    if let drawable = view.currentDrawable {
                        commandBuffer.present(drawable)
                    }
                    commandBuffer.commit()
                    return
                }

                let camera = frame.camera
                let orientation = currentInterfaceOrientation(for: view)
                let viewportSize = CGSize(width: drawableWidth, height: drawableHeight)
                let projection = camera.projectionMatrix(
                    for: orientation,
                    viewportSize: viewportSize,
                    zNear: 0.001,
                    zFar: 1000
                )
                let viewMatrix = camera.viewMatrix(for: orientation)
                let modelTransform = resolvedModelTransform(frame: frame)
                let alignedViewMatrix = viewMatrix * modelTransform

                let screenSize = SIMD2<Int>(
                    x: max(1, Int(drawableWidth.rounded())),
                    y: max(1, Int(drawableHeight.rounded()))
                )

                let cameraDescriptor = SplatRenderer.CameraDescriptor(
                    projectionMatrix: projection,
                    viewMatrix: alignedViewMatrix,
                    screenSize: screenSize
                )

                renderer.willRender(viewportCameras: [cameraDescriptor])
                renderer.render(viewportCameras: [cameraDescriptor], to: renderEncoder)
            }

            renderEncoder.endEncoding()

            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }

            commandBuffer.commit()
        }

        // Drawable size is managed by MTKView's auto-resize.

        private func resolveSplatURL(for url: URL, maxSplats: Int?) -> URL {
            guard let maxSplats else { return url }
            guard let downsampled = try? downsampleIfNeeded(url: url, maxSplats: maxSplats) else {
                return url
            }
            return downsampled
        }

        private func downsampleIfNeeded(url: URL, maxSplats: Int) throws -> URL {
            guard maxSplats > 0 else { return url }

            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return url
            }

            let lines = text.split(whereSeparator: \.isNewline)
            guard let headerEndIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "end_header" }) else {
                return url
            }

            var headerLines = lines[0...headerEndIndex].map(String.init)
            let bodyLines = lines[(headerEndIndex + 1)...].map(String.init)

            guard let vertexLineIndex = headerLines.firstIndex(where: { $0.hasPrefix("element vertex ") }) else {
                return url
            }

            let vertexTokens = headerLines[vertexLineIndex].split(separator: " ")
            guard vertexTokens.count >= 3, let vertexCount = Int(vertexTokens[2]), vertexCount > maxSplats else {
                return url
            }

            let stride = max(1, Int(Double(vertexCount) / Double(maxSplats)))
            var sampled: [String] = []
            sampled.reserveCapacity(maxSplats)
            for (index, line) in bodyLines.enumerated() where index % stride == 0 {
                sampled.append(line)
                if sampled.count >= maxSplats { break }
            }

            headerLines[vertexLineIndex] = "element vertex \(sampled.count)"
            let output = (headerLines + sampled).joined(separator: "\n") + "\n"

            let downsampleURL = url
                .deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_ds\(sampled.count).ply")

            try output.write(to: downsampleURL, atomically: true, encoding: .utf8)
            return downsampleURL
        }

        private func updateFrameStats() {
            let now = CACurrentMediaTime()
            defer { lastFrameTimestamp = now }

            guard let lastFrameTimestamp else { return }
            let delta = now - lastFrameTimestamp
            guard delta > 0 else { return }

            let stats = FrameStats(frameTimeMs: delta * 1000, fps: 1.0 / delta)

            let lastPublish = lastStatsPublishTimestamp ?? 0
            if now - lastPublish > 0.5 {
                lastStatsPublishTimestamp = now
                DispatchQueue.main.async {
                    self.onFrameStatsUpdate?(stats)
                }
            }
        }

        private func resolvedModelTransform(frame: ARFrame) -> simd_float4x4 {
            switch renderMode {
            case .aligned:
                return renderTransform
            case .cameraLocked:
                let forward = simd_float4x4.translation(SIMD3<Float>(0, 0, -1))
                return frame.camera.transform * forward
            case .identity:
                return matrix_identity_float4x4
            }
        }

        private func currentInterfaceOrientation(for view: MTKView) -> UIInterfaceOrientation {
            if #available(iOS 26.0, *), let windowScene = view.window?.windowScene {
                return windowScene.effectiveGeometry.interfaceOrientation
            }
            if let mapped = UIInterfaceOrientation(deviceOrientation: UIDevice.current.orientation) {
                return mapped
            }
            return .portrait
        }
    }
}

struct FrameStats: Equatable {
    let frameTimeMs: Double
    let fps: Double
}

private extension UIInterfaceOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        default: return nil
        }
    }
}

final class ViewerARContainerView: UIView {
    private var cameraFeedVisible = true

    let arView: ARSCNView = {
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        return view
    }()

    let metalView: MTKView = {
        let view = MTKView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        arView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arView)
        addSubview(metalView)

        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: trailingAnchor),
            arView.topAnchor.constraint(equalTo: topAnchor),
            arView.bottomAnchor.constraint(equalTo: bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCameraFeedVisible(_ isVisible: Bool) {
        guard cameraFeedVisible != isVisible else { return }
        cameraFeedVisible = isVisible

        arView.alpha = isVisible ? 1 : 0
        arView.isHidden = !isVisible

        backgroundColor = isVisible ? .clear : .black
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
    }
}

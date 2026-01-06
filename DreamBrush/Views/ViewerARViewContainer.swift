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
    let renderMode: RenderMode
    let onLoadError: (String) -> Void
    let onStatsUpdate: (Int) -> Void

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
            onStatsUpdate: onStatsUpdate
        )
        context.coordinator.updateRenderState(
            shouldRender: shouldRender,
            renderTransform: renderTransform,
            renderMode: renderMode
        )

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
        context.coordinator.updateSplatURL(splatURL)
        context.coordinator.updateCallbacks(onError: onLoadError, onStatsUpdate: onStatsUpdate)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var splatRenderer: SplatRenderer?
        private var currentSplatURL: URL?
        private let inFlightSemaphore = DispatchSemaphore(value: 3)

        private weak var session: ARSession?
        private var shouldRender = false
        private var renderTransform = matrix_identity_float4x4
        private var renderMode: RenderMode = .aligned
        private var onError: ((String) -> Void)?
        private var onStatsUpdate: ((Int) -> Void)?

        func configure(
            metalView: MTKView,
            session: ARSession,
            splatURL: URL?,
            onError: @escaping (String) -> Void,
            onStatsUpdate: @escaping (Int) -> Void
        ) {
            self.session = session
            updateCallbacks(onError: onError, onStatsUpdate: onStatsUpdate)

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
                currentSplatURL = nil
                DispatchQueue.main.async {
                    self.onStatsUpdate?(0)
                }
                return
            }

            guard currentSplatURL != splatURL else { return }
            currentSplatURL = splatURL

            guard let device else { return }
            if commandQueue == nil {
                commandQueue = device.makeCommandQueue()
            }

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
                try renderer.readPLY(from: splatURL)
                splatRenderer = renderer
                let count = renderer.splatCount
                DispatchQueue.main.async {
                    self.onStatsUpdate?(count)
                }
                if count == 0 {
                    DispatchQueue.main.async {
                        self.onError?("Loaded splat file but found 0 points")
                    }
                }
            } catch {
                splatRenderer = nil
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
                            splatRenderer = retry
                            let count = retry.splatCount
                            DispatchQueue.main.async {
                                self.onStatsUpdate?(count)
                            }
                            return
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.onError?("Failed to sanitize splat: \(error.localizedDescription)")
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.onError?("Failed to load splat: \(message)")
                }
            }
        }

        func updateRenderState(shouldRender: Bool, renderTransform: simd_float4x4?, renderMode: RenderMode) {
            self.shouldRender = shouldRender
            self.renderTransform = renderTransform ?? matrix_identity_float4x4
            self.renderMode = renderMode
        }

        func updateCallbacks(onError: @escaping (String) -> Void, onStatsUpdate: @escaping (Int) -> Void) {
            self.onError = onError
            self.onStatsUpdate = onStatsUpdate
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No-op; we read size during draw.
        }

        func draw(in view: MTKView) {
            _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

            guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
                inFlightSemaphore.signal()
                return
            }

            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }

            guard let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                if let drawable = view.currentDrawable {
                    commandBuffer.present(drawable)
                }
                commandBuffer.commit()
                return
            }

            if shouldRender, let renderer = splatRenderer, let frame = session?.currentFrame {
                let camera = frame.camera
                let orientation = currentInterfaceOrientation(for: view)
                let viewportSize = view.bounds.size
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
                    x: Int(view.drawableSize.width),
                    y: Int(view.drawableSize.height)
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
}

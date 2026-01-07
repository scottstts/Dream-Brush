//
//  ARViewContainer.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import ARKit
import SwiftUI
import UIKit
import simd

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    let showCoverageOverlay: Bool
    let isRecording: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true
        arView.scene = SCNScene()
        arView.delegate = context.coordinator
        context.coordinator.attach(to: arView)

        // Show feature points and world origin for debugging
        #if DEBUG
        arView.debugOptions = [.showFeaturePoints]
        #endif

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
        context.coordinator.updateOverlay(isEnabled: showCoverageOverlay && isRecording)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        private weak var arView: ARSCNView?
        private var showCoverageOverlay = false
        private var meshNodes: [UUID: SCNNode] = [:]
        private var meshCoverage: [UUID: [UInt8]] = [:]
        private var lastCoverageUpdate: TimeInterval = 0

        private let updateInterval: TimeInterval = 0.35
        private let vertexSamplingStride = 4
        private let maxCoverage: UInt8 = 6
        private let depthEpsilon: Float = 0.04

        func attach(to view: ARSCNView) {
            arView = view
        }

        func updateOverlay(isEnabled: Bool) {
            showCoverageOverlay = isEnabled
            for node in meshNodes.values {
                node.isHidden = !isEnabled
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = buildMeshNode(for: meshAnchor)
            node.isHidden = !showCoverageOverlay
            meshNodes[meshAnchor.identifier] = node
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.geometry = buildGeometry(for: meshAnchor, coverage: meshCoverage[meshAnchor.identifier])
            meshNodes[meshAnchor.identifier] = node
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            meshNodes[meshAnchor.identifier] = nil
            meshCoverage[meshAnchor.identifier] = nil
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard showCoverageOverlay,
                  let arView,
                  let frame = arView.session.currentFrame else { return }
            guard time - lastCoverageUpdate >= updateInterval else { return }
            lastCoverageUpdate = time

            guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else { return }
            updateCoverage(frame: frame, depthMap: depthMap)
        }

        private func updateCoverage(frame: ARFrame, depthMap: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }

            let depthWidth = CVPixelBufferGetWidth(depthMap)
            let depthHeight = CVPixelBufferGetHeight(depthMap)
            let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
            let depthBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

            let camera = frame.camera
            let intrinsics = camera.intrinsics
            let fx = intrinsics.columns.0.x
            let fy = intrinsics.columns.1.y
            let cx = intrinsics.columns.2.x
            let cy = intrinsics.columns.2.y

            let imageWidth = Float(camera.imageResolution.width)
            let imageHeight = Float(camera.imageResolution.height)
            let scaleX = Float(depthWidth) / imageWidth
            let scaleY = Float(depthHeight) / imageHeight

            let worldToCamera = simd_inverse(camera.transform)

            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            for anchor in meshAnchors {
                let geometry = anchor.geometry
                let vertexCount = geometry.vertices.count

                var coverage = meshCoverage[anchor.identifier] ?? Array(repeating: 0, count: vertexCount)
                if coverage.count != vertexCount {
                    coverage = Array(repeating: 0, count: vertexCount)
                }

                for index in stride(from: 0, to: vertexCount, by: vertexSamplingStride) {
                    let localVertex = geometry.vertex(at: index)
                    let worldVertex = (anchor.transform * SIMD4<Float>(localVertex, 1)).xyz
                    let cameraVertex = worldToCamera * SIMD4<Float>(worldVertex, 1)
                    let z = -cameraVertex.z
                    guard z > 0 else { continue }

                    let u = (cameraVertex.x / -cameraVertex.z) * fx + cx
                    let v = (cameraVertex.y / -cameraVertex.z) * fy + cy

                    let uDepth = Int((u * scaleX).rounded())
                    let vDepth = Int((v * scaleY).rounded())

                    guard uDepth >= 0, vDepth >= 0, uDepth < depthWidth, vDepth < depthHeight else { continue }

                    let depth = depthBuffer[vDepth * depthStride + uDepth]
                    guard depth > 0 else { continue }

                    if abs(depth - z) <= depthEpsilon {
                        let value = min(maxCoverage, coverage[index] &+ 1)
                        coverage[index] = value
                    }
                }

                meshCoverage[anchor.identifier] = coverage

                if let node = meshNodes[anchor.identifier] {
                    node.geometry = buildGeometry(for: anchor, coverage: coverage)
                }
            }
        }

        private func buildMeshNode(for anchor: ARMeshAnchor) -> SCNNode {
            let node = SCNNode()
            node.geometry = buildGeometry(for: anchor, coverage: nil)
            return node
        }

        private func buildGeometry(for anchor: ARMeshAnchor, coverage: [UInt8]?) -> SCNGeometry {
            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            let vertices = scnVectors(from: geometry.vertices, count: vertexCount)
            let normals = scnVectors(from: geometry.normals, count: geometry.normals.count)

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let normalSource = SCNGeometrySource(normals: normals)
            let colorSource = makeColorSource(
                vertexCount: vertexCount,
                coverage: coverage
            )
            let element = geometryElement(from: geometry.faces)

            let scnGeometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.diffuse.contents = UIColor.white
            material.transparency = 0.45
            scnGeometry.materials = [material]
            return scnGeometry
        }

        private func scnVectors(from source: ARGeometrySource, count: Int) -> [SCNVector3] {
            guard count > 0 else { return [] }
            var vectors: [SCNVector3] = []
            vectors.reserveCapacity(count)
            for index in 0..<count {
                let value: (Float, Float, Float) = source[Int32(index)]
                vectors.append(SCNVector3(value.0, value.1, value.2))
            }
            return vectors
        }

        private func geometryElement(from element: ARGeometryElement) -> SCNGeometryElement {
            let faceCount = element.count
            var indices: [Int32] = []
            indices.reserveCapacity(faceCount * 3)
            for index in 0..<faceCount {
                indices.append(contentsOf: element[index])
            }
            return SCNGeometryElement(indices: indices, primitiveType: .triangles)
        }

        private func makeColorSource(vertexCount: Int, coverage: [UInt8]?) -> SCNGeometrySource {
            let colors: [SIMD4<Float>]
            if let coverage, coverage.count == vertexCount {
                colors = coverage.map { colorForCoverage($0) }
            } else {
                colors = Array(repeating: SIMD4<Float>(0.1, 0.5, 1.0, 0.25), count: vertexCount)
            }

            var colorData = colors
            let data = Data(bytes: &colorData, count: MemoryLayout<SIMD4<Float>>.size * colorData.count)
            return SCNGeometrySource(
                data: data,
                semantic: .color,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.size
            )
        }

        private func colorForCoverage(_ coverage: UInt8) -> SIMD4<Float> {
            let t = min(1, Float(coverage) / Float(maxCoverage))
            let r = 1 - t
            let g: Float = 0.2 + 0.8 * t
            let b: Float = 0.2
            return SIMD4<Float>(r, g, b, 0.45)
        }
    }
}

private extension ARMeshGeometry {
    func vertex(at index: Int) -> SIMD3<Float> {
        let value: (Float, Float, Float) = vertices[Int32(index)]
        return SIMD3<Float>(value.0, value.1, value.2)
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

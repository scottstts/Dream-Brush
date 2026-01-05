//
//  CaptureBundleManager.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import Foundation
import os.log

final class CaptureBundleManager: @unchecked Sendable {
    static let shared = CaptureBundleManager()

    private let logger = Logger(subsystem: "com.scottsun.DreamBrush", category: "CaptureBundleManager")
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    private var bundlesDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CaptureBundles", isDirectory: true)
    }

    private init() {
        jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601

        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601

        ensureBundlesDirectoryExists()
    }

    private func ensureBundlesDirectoryExists() {
        do {
            if !fileManager.fileExists(atPath: bundlesDirectory.path) {
                try fileManager.createDirectory(at: bundlesDirectory, withIntermediateDirectories: true)
                logger.info("Created bundles directory at \(self.bundlesDirectory.path)")
            }
        } catch {
            logger.error("Failed to create bundles directory: \(error.localizedDescription)")
        }
    }

    func createBundle(settings: CaptureSettings = CaptureSettings()) throws -> CaptureBundle {
        let bundleId = UUID().uuidString
        let bundleName = "CaptureBundle_\(bundleId)"
        let bundleURL = bundlesDirectory.appendingPathComponent(bundleName, isDirectory: true)

        logger.info("Creating bundle at \(bundleURL.path)")

        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let subdirectories = [
            "keyframes",
            "frames/rgb",
            "frames/depth",
            "frames/meta"
        ]

        for subdirectory in subdirectories {
            let subURL = bundleURL.appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: subURL, withIntermediateDirectories: true)
        }

        var manifest = CaptureManifest(bundleId: bundleId, captureSettings: settings)
        try writeManifest(manifest, to: bundleURL)

        let anchors = AnchorData(rootAnchor: AnchorInfo())
        try writeAnchors(anchors, to: bundleURL)

        logger.info("Successfully created bundle \(bundleId)")

        return CaptureBundle(manifest: manifest, bundleURL: bundleURL)
    }

    func writeManifest(_ manifest: CaptureManifest, to bundleURL: URL) throws {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let data = try jsonEncoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        logger.debug("Wrote manifest to \(manifestURL.path)")
    }

    func writeAnchors(_ anchors: AnchorData, to bundleURL: URL) throws {
        let anchorsURL = bundleURL.appendingPathComponent("anchors.json")
        let data = try jsonEncoder.encode(anchors)
        try data.write(to: anchorsURL, options: .atomic)
        logger.debug("Wrote anchors to \(anchorsURL.path)")
    }

    func writeFrameMetadata(_ metadata: FrameMetadata, to bundleURL: URL) throws {
        let fileName = String(format: "%06d.json", metadata.frameIndex)
        let metaURL = bundleURL.appendingPathComponent("frames/meta/\(fileName)")
        let data = try jsonEncoder.encode(metadata)
        try data.write(to: metaURL, options: .atomic)
    }

    func loadBundle(at bundleURL: URL) throws -> CaptureBundle {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw CaptureBundleError.manifestNotFound
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try jsonDecoder.decode(CaptureManifest.self, from: data)

        logger.info("Loaded bundle \(manifest.bundleId)")

        return CaptureBundle(manifest: manifest, bundleURL: bundleURL)
    }

    func validateBundle(_ bundle: CaptureBundle) -> ValidationResult {
        var issues: [String] = []

        let manifestURL = bundle.bundleURL.appendingPathComponent("manifest.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            issues.append("manifest.json not found")
        } else {
            do {
                let data = try Data(contentsOf: manifestURL)
                _ = try jsonDecoder.decode(CaptureManifest.self, from: data)
            } catch {
                issues.append("manifest.json is invalid: \(error.localizedDescription)")
            }
        }

        let anchorsURL = bundle.bundleURL.appendingPathComponent("anchors.json")
        if !fileManager.fileExists(atPath: anchorsURL.path) {
            issues.append("anchors.json not found")
        }

        let requiredDirs = ["frames/rgb", "frames/depth", "frames/meta", "keyframes"]
        for dir in requiredDirs {
            let dirURL = bundle.bundleURL.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir) || !isDir.boolValue {
                issues.append("Directory '\(dir)' not found")
            }
        }

        return ValidationResult(isValid: issues.isEmpty, issues: issues)
    }

    func listBundles() -> [CaptureBundle] {
        var bundles: [CaptureBundle] = []

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: bundlesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )

            for url in contents {
                guard url.hasDirectoryPath else { continue }
                guard url.lastPathComponent.hasPrefix("CaptureBundle_") else { continue }

                do {
                    let bundle = try loadBundle(at: url)
                    bundles.append(bundle)
                } catch {
                    logger.warning("Failed to load bundle at \(url.path): \(error.localizedDescription)")
                }
            }

            bundles.sort { $0.manifest.createdAt > $1.manifest.createdAt }
        } catch {
            logger.error("Failed to list bundles: \(error.localizedDescription)")
        }

        return bundles
    }

    func deleteBundle(_ bundle: CaptureBundle) throws {
        try fileManager.removeItem(at: bundle.bundleURL)
        logger.info("Deleted bundle \(bundle.manifest.bundleId)")
    }

    func updateManifest(for bundle: inout CaptureBundle, update: (inout CaptureManifest) -> Void) throws {
        var manifest = bundle.manifest
        update(&manifest)
        try writeManifest(manifest, to: bundle.bundleURL)
        bundle = CaptureBundle(manifest: manifest, bundleURL: bundle.bundleURL)
    }
}

enum CaptureBundleError: LocalizedError {
    case manifestNotFound
    case invalidManifest
    case bundleCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "manifest.json not found in bundle"
        case .invalidManifest:
            return "manifest.json is invalid or corrupted"
        case .bundleCreationFailed(let reason):
            return "Failed to create bundle: \(reason)"
        }
    }
}

struct ValidationResult {
    let isValid: Bool
    let issues: [String]
}

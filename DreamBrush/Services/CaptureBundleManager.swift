//
//  CaptureBundleManager.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import ARKit
import Foundation
import os.log
import UIKit

final class CaptureBundleManager: @unchecked Sendable {
    static let shared = CaptureBundleManager()

    private let logger = Logger(subsystem: "com.scottsun.DreamBrush", category: "CaptureBundleManager")
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private let thumbnailCache = NSCache<NSString, UIImage>()

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

        let manifest = CaptureManifest(bundleId: bundleId, captureSettings: settings)
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

    // MARK: - World Map Persistence

    /// Writes an ARWorldMap to the bundle as worldmap.arexperience
    func writeWorldMap(_ worldMap: ARWorldMap, to bundleURL: URL) throws {
        let worldMapURL = bundleURL.appendingPathComponent("worldmap.arexperience")
        let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try data.write(to: worldMapURL, options: .atomic)
        logger.info("Wrote world map to \(worldMapURL.path) (\(data.count) bytes)")
    }

    /// Loads an ARWorldMap from the bundle
    func loadWorldMap(from bundleURL: URL) throws -> ARWorldMap {
        let worldMapURL = bundleURL.appendingPathComponent("worldmap.arexperience")

        guard fileManager.fileExists(atPath: worldMapURL.path) else {
            throw CaptureBundleError.worldMapNotFound
        }

        let data = try Data(contentsOf: worldMapURL)
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CaptureBundleError.invalidWorldMap
        }

        logger.info("Loaded world map from \(worldMapURL.path)")
        return worldMap
    }

    /// Checks if a world map exists for the bundle
    func hasWorldMap(at bundleURL: URL) -> Bool {
        let worldMapURL = bundleURL.appendingPathComponent("worldmap.arexperience")
        return fileManager.fileExists(atPath: worldMapURL.path)
    }

    /// Loads anchor data from the bundle
    func loadAnchors(from bundleURL: URL) throws -> AnchorData {
        let anchorsURL = bundleURL.appendingPathComponent("anchors.json")

        guard fileManager.fileExists(atPath: anchorsURL.path) else {
            throw CaptureBundleError.anchorsNotFound
        }

        let data = try Data(contentsOf: anchorsURL)
        let anchors = try jsonDecoder.decode(AnchorData.self, from: data)
        logger.debug("Loaded anchors from \(anchorsURL.path)")
        return anchors
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
        var warnings: [String] = []

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

        // World map is important but not strictly required (older bundles may not have it)
        let worldMapURL = bundle.bundleURL.appendingPathComponent("worldmap.arexperience")
        if !fileManager.fileExists(atPath: worldMapURL.path) {
            warnings.append("worldmap.arexperience not found - relocalization will not be available")
        }

        let requiredDirs = ["frames/rgb", "frames/depth", "frames/meta", "keyframes"]
        for dir in requiredDirs {
            let dirURL = bundle.bundleURL.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir) || !isDir.boolValue {
                issues.append("Directory '\(dir)' not found")
            }
        }

        return ValidationResult(isValid: issues.isEmpty, issues: issues, warnings: warnings)
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

    func listBundlesAsync() async -> [CaptureBundle] {
        let directory = bundlesDirectory
        let entries: [(URL, Data)] = await Task.detached(priority: .utility) { () -> [(URL, Data)] in
            var results: [(URL, Data)] = []
            let fileManager = FileManager.default

            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return results
            }

            for url in contents {
                guard url.hasDirectoryPath else { continue }
                guard url.lastPathComponent.hasPrefix("CaptureBundle_") else { continue }

                let manifestURL = url.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL) else { continue }
                results.append((url, data))
            }

            return results
        }.value

        var bundles: [CaptureBundle] = []
        for (url, data) in entries {
            do {
                let manifest = try jsonDecoder.decode(CaptureManifest.self, from: data)
                bundles.append(CaptureBundle(manifest: manifest, bundleURL: url))
            } catch {
                logger.warning("Failed to load bundle at \(url.path): \(error.localizedDescription)")
            }
        }

        bundles.sort { $0.manifest.createdAt > $1.manifest.createdAt }
        return bundles
    }

    func deleteBundle(_ bundle: CaptureBundle) throws {
        try fileManager.removeItem(at: bundle.bundleURL)
        thumbnailCache.removeObject(forKey: bundle.manifest.bundleId as NSString)
        logger.info("Deleted bundle \(bundle.manifest.bundleId)")
    }

    func loadThumbnail(for bundle: CaptureBundle) async -> UIImage? {
        let cacheKey = bundle.manifest.bundleId
        if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let thumbURL = bundle.bundleURL.appendingPathComponent("thumb.jpg")
        let image: UIImage? = await Task.detached(priority: .utility) { [thumbURL] () -> UIImage? in
            guard let data = try? Data(contentsOf: thumbURL),
                  let image = UIImage(data: data) else {
                return nil
            }
            return image
        }.value

        if let image {
            thumbnailCache.setObject(image, forKey: cacheKey as NSString)
        }
        return image
    }


    func updateManifest(for bundle: inout CaptureBundle, update: (inout CaptureManifest) -> Void) throws {
        var updatedManifest = bundle.manifest
        update(&updatedManifest)
        try writeManifest(updatedManifest, to: bundle.bundleURL)
        bundle = CaptureBundle(manifest: updatedManifest, bundleURL: bundle.bundleURL)
    }
}

enum CaptureBundleError: LocalizedError {
    case manifestNotFound
    case invalidManifest
    case bundleCreationFailed(String)
    case worldMapNotFound
    case invalidWorldMap
    case anchorsNotFound

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "manifest.json not found in bundle"
        case .invalidManifest:
            return "manifest.json is invalid or corrupted"
        case .bundleCreationFailed(let reason):
            return "Failed to create bundle: \(reason)"
        case .worldMapNotFound:
            return "worldmap.arexperience not found in bundle"
        case .invalidWorldMap:
            return "worldmap.arexperience is invalid or corrupted"
        case .anchorsNotFound:
            return "anchors.json not found in bundle"
        }
    }
}

struct ValidationResult {
    let isValid: Bool
    let issues: [String]
    let warnings: [String]

    init(isValid: Bool, issues: [String], warnings: [String] = []) {
        self.isValid = isValid
        self.issues = issues
        self.warnings = warnings
    }
}

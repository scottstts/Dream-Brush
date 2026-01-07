//
//  SplatAssetManager.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import Foundation
import Metal
import MetalSplatter
import UniformTypeIdentifiers
import os.log

struct SplatAssetValidationResult {
    let success: Bool
    let details: String
    let gaussianCount: Int?
    let format: String?
}

enum SplatAssetValidationError: LocalizedError {
    case unsupportedExtension(String)
    case unreadableHeader
    case invalidHeader
    case missingEndHeader
    case renderValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext):
            return "Unsupported file type: .\(ext)"
        case .unreadableHeader:
            return "Could not read PLY header."
        case .invalidHeader:
            return "PLY header is invalid."
        case .missingEndHeader:
            return "PLY header did not include end_header."
        case .renderValidationFailed(let reason):
            return "MetalSplatter validation failed: \(reason)"
        }
    }
}

struct PlyHeaderInfo {
    let vertexCount: Int?
    let format: String?
}

private struct AlignmentPayload: Codable {
    let modelToCaptureTransform: [[Float]]?
    let modelToCapture4x4: [[Float]]?
    let modelToAnchor4x4: [[Float]]?
    let scale: Float?

    enum CodingKeys: String, CodingKey {
        case modelToCaptureTransform
        case modelToCapture4x4 = "model_to_capture_4x4"
        case modelToAnchor4x4 = "model_to_anchor_4x4"
        case scale
    }
}

enum SplatAssetValidator {
    private static let headerTerminator = "end_header"
    private static let headerTerminatorData = Data(headerTerminator.utf8)

    static func parsePlyHeader(from url: URL) throws -> PlyHeaderInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let maxHeaderSize = 256 * 1024
        var buffer = Data()

        while buffer.count < maxHeaderSize {
            if let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                buffer.append(chunk)
                if buffer.range(of: headerTerminatorData) != nil {
                    break
                }
            } else {
                break
            }
        }

        return try parsePlyHeader(from: buffer)
    }

    static func parsePlyHeader(from data: Data) throws -> PlyHeaderInfo {
        let headerData = try extractHeaderData(from: data)

        guard let text = String(data: headerData, encoding: .ascii)
            ?? String(data: headerData, encoding: .utf8) else {
            throw SplatAssetValidationError.unreadableHeader
        }

        let lines = text.components(separatedBy: .newlines)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              firstLine == "ply" else {
            throw SplatAssetValidationError.invalidHeader
        }

        var vertexCount: Int?
        var format: String?
        var foundEndHeader = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let tokens = trimmed.split(separator: " ").map(String.init)
            if tokens.count >= 2, tokens[0] == "format" {
                format = tokens.dropFirst().joined(separator: " ")
            }
            if tokens.count >= 3, tokens[0] == "element", tokens[1] == "vertex" {
                vertexCount = Int(tokens[2])
            }
            if trimmed == headerTerminator {
                foundEndHeader = true
                break
            }
        }

        guard foundEndHeader else {
            throw SplatAssetValidationError.missingEndHeader
        }

        return PlyHeaderInfo(vertexCount: vertexCount, format: format)
    }

    private static func extractHeaderData(from data: Data) throws -> Data {
        guard let range = data.range(of: headerTerminatorData) else {
            throw SplatAssetValidationError.missingEndHeader
        }

        var endIndex = range.upperBound
        if endIndex < data.endIndex {
            while endIndex < data.endIndex {
                let byte = data[endIndex]
                endIndex = data.index(after: endIndex)
                if byte == 0x0A { // \n
                    break
                }
            }
        }

        return data.subdata(in: data.startIndex..<endIndex)
    }
}

final class SplatAssetManager: @unchecked Sendable {
    static let shared = SplatAssetManager()

    static let supportedExtensions = ["ply"]
    static let supportedContentTypes: [UTType] = {
        let declaredType = UTType(importedAs: "com.scottsun.dreambrush.ply")
        let plyType = UTType(filenameExtension: "ply")
            ?? UTType(tag: "ply", tagClass: .filenameExtension, conformingTo: .data)
        return [declaredType, plyType].compactMap { $0 }
    }()

    private let logger = Logger(subsystem: "com.scottsun.DreamBrush", category: "SplatAssetManager")
    private let fileManager: FileManager
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private let assetsDirectory: URL

    init(
        fileManager: FileManager = .default,
        assetsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.assetsDirectory = assetsDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SplatAssets", isDirectory: true)

        jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601

        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601

        ensureAssetsDirectoryExists()
    }

    private func ensureAssetsDirectoryExists() {
        do {
            if !fileManager.fileExists(atPath: assetsDirectory.path) {
                try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
                logger.info("Created splat assets directory at \(self.assetsDirectory.path)")
            }
        } catch {
            logger.error("Failed to create splat assets directory: \(error.localizedDescription)")
        }
    }

    func listAssets() -> [SplatAsset] {
        ensureAssetsDirectoryExists()

        guard let contents = try? fileManager.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var assets: [SplatAsset] = []

        for url in contents where url.hasDirectoryPath {
            let manifestURL = url.appendingPathComponent("asset.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }

            do {
                let data = try Data(contentsOf: manifestURL)
                let asset = try jsonDecoder.decode(SplatAsset.self, from: data)
                assets.append(asset)
            } catch {
                logger.error("Failed to decode asset at \(manifestURL.path): \(error.localizedDescription)")
            }
        }

        return assets.sorted { $0.importedAt > $1.importedAt }
    }

    @MainActor
    func listAssetsAsync() async -> [SplatAsset] {
        listAssets()
    }

    func importAsset(from sourceURL: URL, associatedBundleId: String? = nil) throws -> SplatAsset {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw SplatAssetValidationError.unsupportedExtension(fileExtension)
        }

        let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let assetId = UUID().uuidString
        let assetFolder = assetsDirectory.appendingPathComponent("SplatAsset_\(assetId)", isDirectory: true)
        try fileManager.createDirectory(at: assetFolder, withIntermediateDirectories: true)

        var didComplete = false
        defer {
            if !didComplete {
                try? fileManager.removeItem(at: assetFolder)
            }
        }

        let destinationURL = assetFolder.appendingPathComponent(sourceURL.lastPathComponent)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let modelToCaptureTransform = loadAlignmentTransform(for: sourceURL)

        _ = try sanitizeObjInfoLinesIfNeeded(at: destinationURL)
        let gaussianCount = try validateWithMetalSplatter(at: destinationURL)
        let fileSize = try fileSizeForItem(at: destinationURL)
        let displayName = sourceURL.deletingPathExtension().lastPathComponent

        let asset = SplatAsset(
            id: assetId,
            name: displayName,
            fileURL: destinationURL,
            fileSize: fileSize,
            importedAt: Date(),
            gaussianCount: gaussianCount,
            associatedBundleId: associatedBundleId,
            modelToCaptureTransform: modelToCaptureTransform
        )

        try persistAsset(asset)
        didComplete = true
        logger.info("Imported splat asset \(asset.name, privacy: .public) at \(destinationURL.path)")
        return asset
    }

    func deleteAsset(_ asset: SplatAsset) throws {
        let assetFolder = directoryForAsset(id: asset.id)
        guard fileManager.fileExists(atPath: assetFolder.path) else { return }
        try fileManager.removeItem(at: assetFolder)
    }

    func updateAsset(_ asset: SplatAsset) throws {
        try persistAsset(asset)
    }

    func validateAsset(_ asset: SplatAsset) -> SplatAssetValidationResult {
        let url = asset.fileURL
        let fileExtension = url.pathExtension.lowercased()

        guard Self.supportedExtensions.contains(fileExtension) else {
            return SplatAssetValidationResult(
                success: false,
                details: "Unsupported format: .\(fileExtension).",
                gaussianCount: nil,
                format: nil
            )
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return SplatAssetValidationResult(
                success: false,
                details: "File not found in app storage.",
                gaussianCount: nil,
                format: nil
            )
        }

        do {
            _ = try sanitizeObjInfoLinesIfNeeded(at: url)
            let gaussianCount = try validateWithMetalSplatter(at: url)
            let details = "MetalSplatter validation OK."
            return SplatAssetValidationResult(
                success: true,
                details: details,
                gaussianCount: gaussianCount,
                format: "metalSplatter"
            )
        } catch {
            return SplatAssetValidationResult(
                success: false,
                details: error.localizedDescription,
                gaussianCount: nil,
                format: nil
            )
        }
    }

    private func persistAsset(_ asset: SplatAsset) throws {
        let assetFolder = directoryForAsset(id: asset.id)
        if !fileManager.fileExists(atPath: assetFolder.path) {
            try fileManager.createDirectory(at: assetFolder, withIntermediateDirectories: true)
        }

        let manifestURL = assetFolder.appendingPathComponent("asset.json")
        let data = try jsonEncoder.encode(asset)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func directoryForAsset(id: String) -> URL {
        assetsDirectory.appendingPathComponent("SplatAsset_\(id)", isDirectory: true)
    }

    private func fileSizeForItem(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return Int64((try Data(contentsOf: url)).count)
    }

    private func loadAlignmentTransform(for sourceURL: URL) -> [[Float]]? {
        let directory = sourceURL.deletingLastPathComponent()
        let alignmentURL = directory.appendingPathComponent("alignment.json")
        guard fileManager.fileExists(atPath: alignmentURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: alignmentURL)
            let payload = try jsonDecoder.decode(AlignmentPayload.self, from: data)
            var transform = payload.modelToCaptureTransform
                ?? payload.modelToCapture4x4
                ?? payload.modelToAnchor4x4

            if var matrix = transform, let scale = payload.scale, scale != 1 {
                matrix = applyUniformScale(scale, to: matrix)
                transform = matrix
            }

            return transform
        } catch {
            logger.warning("Failed to load alignment.json: \(error.localizedDescription)")
            return nil
        }
    }

    private func applyUniformScale(_ scale: Float, to matrix: [[Float]]) -> [[Float]] {
        guard matrix.count == 4, matrix.allSatisfy({ $0.count == 4 }) else { return matrix }
        var scaled = matrix
        for col in 0..<3 {
            for row in 0..<4 {
                scaled[col][row] *= scale
            }
        }
        return scaled
    }

    private func validateWithMetalSplatter(at url: URL) throws -> Int {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SplatAssetValidationError.renderValidationFailed("Metal device unavailable")
        }

        let renderer = try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm_srgb,
            depthFormat: .depth32Float_stencil8,
            stencilFormat: .depth32Float_stencil8,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 1
        )
        try renderer.readPLY(from: url)
        return renderer.splatCount
    }

    /// Removes unsupported `obj_info` lines from PLY headers (MetalSplatter parser is strict).
    @discardableResult
    func sanitizeObjInfoLinesIfNeeded(at url: URL) throws -> Bool {
        let headerScan = try scanPlyHeader(from: url)

        guard let text = String(data: headerScan.headerData, encoding: .ascii)
            ?? String(data: headerScan.headerData, encoding: .utf8) else {
            return false
        }

        let lines = text.components(separatedBy: .newlines)
        var sanitizedLines: [String] = []
        var removed = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("obj_info") {
                removed = true
                continue
            }
            sanitizedLines.append(trimmed)
        }

        guard removed else { return false }

        let sanitizedHeader = sanitizedLines.joined(separator: "\n") + "\n"
        let sanitizedHeaderData = Data(sanitizedHeader.utf8)

        let tempURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".sanitized")

        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: tempURL)
        defer { try? output.close() }

        try output.write(contentsOf: sanitizedHeaderData)
        if !headerScan.remainder.isEmpty {
            try output.write(contentsOf: headerScan.remainder)
        }

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(headerScan.bytesConsumed))

        while true {
            if let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            } else {
                break
            }
        }

        _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
        logger.info("Sanitized obj_info lines from PLY header at \(url.lastPathComponent, privacy: .public)")
        return true
    }

    private struct HeaderScanResult {
        let headerData: Data
        let bytesConsumed: Int
        let remainder: Data
    }

    private func scanPlyHeader(from url: URL) throws -> HeaderScanResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let maxHeaderSize = 256 * 1024
        let headerTerminatorData = Data("end_header".utf8)
        var buffer = Data()

        while buffer.count < maxHeaderSize {
            if let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                buffer.append(chunk)
                if buffer.range(of: headerTerminatorData) != nil {
                    break
                }
            } else {
                break
            }
        }

        guard let range = buffer.range(of: headerTerminatorData) else {
            throw SplatAssetValidationError.missingEndHeader
        }

        var endIndex = range.upperBound
        if endIndex < buffer.endIndex {
            while endIndex < buffer.endIndex {
                let byte = buffer[endIndex]
                endIndex = buffer.index(after: endIndex)
                if byte == 0x0A { break }
            }
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<endIndex)
        let remainder = buffer.subdata(in: endIndex..<buffer.endIndex)

        return HeaderScanResult(
            headerData: headerData,
            bytesConsumed: endIndex,
            remainder: remainder
        )
    }
}

//
//  SplatAssetManager.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import Foundation
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
        }
    }
}

struct PlyHeaderInfo {
    let vertexCount: Int?
    let format: String?
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

        let headerInfo = try SplatAssetValidator.parsePlyHeader(from: destinationURL)
        let fileSize = try fileSizeForItem(at: destinationURL)
        let displayName = sourceURL.deletingPathExtension().lastPathComponent

        let asset = SplatAsset(
            id: assetId,
            name: displayName,
            fileURL: destinationURL,
            fileSize: fileSize,
            importedAt: Date(),
            gaussianCount: headerInfo.vertexCount,
            associatedBundleId: associatedBundleId
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
            let headerInfo = try SplatAssetValidator.parsePlyHeader(from: url)
            let format = headerInfo.format ?? "unknown"
            let details = "PLY header OK (format: \(format))."
            return SplatAssetValidationResult(
                success: true,
                details: details,
                gaussianCount: headerInfo.vertexCount,
                format: format
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
}

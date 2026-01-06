//
//  SplatAsset.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import Foundation

struct SplatAsset: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let fileURL: URL
    let fileSize: Int64
    let importedAt: Date
    let gaussianCount: Int?
    let associatedBundleId: String?

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedGaussianCount: String? {
        guard let gaussianCount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: gaussianCount))
    }

    var fileExtension: String {
        fileURL.pathExtension.lowercased()
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        fileURL: URL,
        fileSize: Int64,
        importedAt: Date = Date(),
        gaussianCount: Int? = nil,
        associatedBundleId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.gaussianCount = gaussianCount
        self.associatedBundleId = associatedBundleId
    }
}

extension SplatAsset {
    func updatingAssociation(_ bundleId: String?) -> SplatAsset {
        SplatAsset(
            id: id,
            name: name,
            fileURL: fileURL,
            fileSize: fileSize,
            importedAt: importedAt,
            gaussianCount: gaussianCount,
            associatedBundleId: bundleId
        )
    }

    func updatingGaussianCount(_ gaussianCount: Int?) -> SplatAsset {
        SplatAsset(
            id: id,
            name: name,
            fileURL: fileURL,
            fileSize: fileSize,
            importedAt: importedAt,
            gaussianCount: gaussianCount,
            associatedBundleId: associatedBundleId
        )
    }
}

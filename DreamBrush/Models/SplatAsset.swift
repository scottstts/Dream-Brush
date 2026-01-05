//
//  SplatAsset.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import Foundation

struct SplatAsset: Identifiable, Codable {
    let id: String
    let name: String
    let fileURL: URL
    let fileSize: Int64
    let importedAt: Date
    let associatedBundleId: String?

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        fileURL: URL,
        fileSize: Int64,
        associatedBundleId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.importedAt = Date()
        self.associatedBundleId = associatedBundleId
    }
}

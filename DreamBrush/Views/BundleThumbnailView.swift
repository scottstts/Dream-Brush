//
//  BundleThumbnailView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import SwiftUI
import UIKit

struct BundleThumbnailView: View {
    let bundle: CaptureBundle
    let size: CGFloat
    let placeholderSystemImage: String

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: placeholderSystemImage)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: bundle.id) {
            thumbnail = await CaptureBundleManager.shared.loadThumbnail(for: bundle)
        }
    }
}

#Preview {
    BundleThumbnailView(
        bundle: CaptureBundle(manifest: CaptureManifest(), bundleURL: URL(fileURLWithPath: "/tmp")),
        size: 60,
        placeholderSystemImage: "photo.stack"
    )
}

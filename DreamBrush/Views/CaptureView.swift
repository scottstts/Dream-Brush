//
//  CaptureView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

struct CaptureView: View {
    @State private var lastCreatedBundle: CaptureBundle?
    @State private var validationResult: ValidationResult?
    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)

                Text("Capture Mode")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Scan interior spaces using ARKit and LiDAR")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                if let bundle = lastCreatedBundle {
                    VStack(spacing: 8) {
                        Text("Last Bundle Created")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(bundle.manifest.bundleId.prefix(8) + "...")
                            .font(.system(.body, design: .monospaced))

                        if let result = validationResult {
                            Label(
                                result.isValid ? "Valid" : "Invalid",
                                systemImage: result.isValid ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(result.isValid ? .green : .red)
                            .font(.caption)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: testBundleCreation) {
                        Label("Test Bundle Creation", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    Button(action: {
                        // TODO: Start capture session
                    }) {
                        Label("Start Capture", systemImage: "record.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
            .navigationTitle("Capture")
            .alert("Bundle Test", isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func testBundleCreation() {
        do {
            let bundle = try CaptureBundleManager.shared.createBundle()

            let loadedBundle = try CaptureBundleManager.shared.loadBundle(at: bundle.bundleURL)

            let result = CaptureBundleManager.shared.validateBundle(loadedBundle)

            lastCreatedBundle = loadedBundle
            validationResult = result

            if result.isValid {
                alertMessage = "Bundle created and validated successfully!\n\nBundle ID: \(bundle.manifest.bundleId.prefix(8))...\nDevice: \(bundle.manifest.deviceModel)"
            } else {
                alertMessage = "Bundle created but validation failed:\n\(result.issues.joined(separator: "\n"))"
            }
            showingAlert = true

        } catch {
            alertMessage = "Failed to create bundle: \(error.localizedDescription)"
            showingAlert = true
        }
    }
}

#Preview {
    CaptureView()
}

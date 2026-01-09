//
//  CaptureSessionView.swift
//  DreamBrush
//
//  Panorama-style capture UI.
//

import ARKit
import SwiftUI

struct CaptureSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessionManager = GuidedCaptureSessionManager()
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            ARViewContainer(
                session: sessionManager.session ?? ARSession(),
                showCoverageOverlay: false,
                isRecording: sessionManager.isCapturing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                topStatusBar
                    .padding(.horizontal)
                    .padding(.top, 8)

                Spacer()

                captureGuide

                Spacer()

                bottomControls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
            }
        }
        .onAppear {
            _ = sessionManager.createSession()
            sessionManager.startSession()
        }
        .onDisappear {
            sessionManager.pauseSession()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: sessionManager.isCaptureComplete) { _, isComplete in
            if isComplete {
                dismiss()
            }
        }
        .navigationBarBackButtonHidden(sessionManager.isCapturing)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !sessionManager.isCapturing {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack(spacing: 12) {
            StatusPill(
                title: "Tracking",
                value: sessionManager.trackingState.displayName,
                color: sessionManager.trackingState.color
            )

            StatusPill(
                title: "Mapping",
                value: sessionManager.worldMappingStatus.displayName,
                color: sessionManager.worldMappingStatus.color
            )

            StatusPill(
                title: "Upright",
                value: sessionManager.isUpright ? "Good" : "Adjust",
                color: sessionManager.isUpright ? .green : .orange
            )
        }
    }

    // MARK: - Capture Guide

    private var captureGuide: some View {
        VStack(spacing: 12) {
            Text("Panorama Capture")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(sessionManager.alignmentHint)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            ProgressView(value: min(sessionManager.yawProgressDegrees / 360, 1))
                .tint(.green)

            Text("\(sessionManager.captureCount) photos")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if sessionManager.isCapturing {
                if sessionManager.canManualCapture {
                    Button(action: sessionManager.captureFirstManually) {
                        Label("Capture First Wall", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                }

                Button(action: sessionManager.cancelCapture) {
                    Label("Stop Capture", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.85))
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
            } else {
                Button(action: startCapture) {
                    Label("Start Capture", systemImage: "camera.circle")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
            }
        }
    }

    private func startCapture() {
        do {
            _ = try sessionManager.beginCapture()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - Supporting Views

struct StatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))

            Text(value)
                .font(.caption.bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

// MARK: - Extensions

extension ARCamera.TrackingState {
    var displayName: String {
        switch self {
        case .notAvailable: return "N/A"
        case .limited: return "Limited"
        case .normal: return "Good"
        }
    }

    var color: Color {
        switch self {
        case .notAvailable: return .red
        case .limited: return .orange
        case .normal: return .green
        }
    }
}

extension ARFrame.WorldMappingStatus {
    var displayName: String {
        switch self {
        case .notAvailable: return "N/A"
        case .limited: return "Limited"
        case .extending: return "Extending"
        case .mapped: return "Mapped"
        @unknown default: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .notAvailable: return .red
        case .limited: return .orange
        case .extending: return .yellow
        case .mapped: return .green
        @unknown default: return .gray
        }
    }
}

#Preview {
    NavigationStack {
        CaptureSessionView()
    }
}

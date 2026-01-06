//
//  CaptureSessionView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import ARKit
import SwiftUI

struct CaptureSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessionManager = CaptureSessionManager()
    @State private var currentBundle: CaptureBundle?
    @State private var showingStopConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var captureCompleted = false

    var body: some View {
        ZStack {
            // AR Camera Preview
            ARViewContainer(session: sessionManager.session ?? ARSession())
                .ignoresSafeArea()

            // Overlay UI
            VStack {
                // Top status bar
                topStatusBar
                    .padding(.top, 8)

                Spacer()

                // Bottom controls
                bottomControls
                    .padding(.bottom, 30)
            }

            // Recording indicator
            if sessionManager.isRecording {
                recordingOverlay
            }
        }
        .onAppear {
            setupSession()
        }
        .onDisappear {
            sessionManager.pauseSession()
        }
        .alert("Stop Recording?", isPresented: $showingStopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Stop & Save", role: .destructive) {
                Task {
                    await stopRecording()
                }
            }
        } message: {
            Text("This will finalize the capture bundle with \(sessionManager.frameCount) frames.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: captureCompleted) { _, completed in
            if completed {
                dismiss()
            }
        }
        .navigationBarBackButtonHidden(sessionManager.isRecording)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !sessionManager.isRecording {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        VStack(spacing: 8) {
            // Tracking & Mapping Status
            HStack(spacing: 16) {
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

                if sessionManager.depthAvailable {
                    StatusPill(
                        title: "Depth",
                        value: "On",
                        color: .green
                    )
                }
            }

            // Recording stats (only when recording)
            if sessionManager.isRecording {
                recordingStats
            }
        }
        .padding(.horizontal)
    }

    private var recordingStats: some View {
        HStack(spacing: 20) {
            StatView(icon: "photo.stack", value: "\(sessionManager.frameCount)", label: "Frames")
            StatView(icon: "star.fill", value: "\(sessionManager.keyframeCount)", label: "Keyframes")
            StatView(icon: "cube", value: "\(sessionManager.depthFrameCount)", label: "Depth")
            StatView(icon: "internaldrive", value: formatBytes(sessionManager.estimatedStorageBytes), label: "Size")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            // Duration display when recording
            if sessionManager.isRecording {
                Text(formatDuration(sessionManager.recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
            }

            // Main control button
            HStack(spacing: 40) {
                if sessionManager.isRecording {
                    // Stop button
                    Button(action: { showingStopConfirmation = true }) {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 80, height: 80)

                            RoundedRectangle(cornerRadius: 8)
                                .fill(.red)
                                .frame(width: 32, height: 32)
                        }
                    }
                } else {
                    // Start recording button
                    Button(action: startRecording) {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 80, height: 80)

                            Circle()
                                .fill(.red)
                                .frame(width: 64, height: 64)
                        }
                    }
                    .disabled(!canStartRecording)
                    .opacity(canStartRecording ? 1.0 : 0.5)
                }
            }

            // Helper text
            if !sessionManager.isRecording {
                Text(canStartRecording ? "Tap to start recording" : "Waiting for good tracking...")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                Text("Move slowly around the space")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Recording Overlay

    private var recordingOverlay: some View {
        VStack {
            HStack {
                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .modifier(PulsingModifier())

                    Text("REC")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.8))
                .cornerRadius(20)
                .padding()
            }

            Spacer()
        }
    }

    // MARK: - Computed Properties

    private var canStartRecording: Bool {
        sessionManager.isSessionRunning &&
            sessionManager.trackingState == .normal
    }

    // MARK: - Actions

    private func setupSession() {
        _ = sessionManager.createSession()
        sessionManager.startSession()
    }

    private func startRecording() {
        do {
            currentBundle = try sessionManager.startRecording()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func stopRecording() async {
        do {
            let bundle = try await sessionManager.stopRecording()
            currentBundle = bundle
            captureCompleted = true
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

struct StatView: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(value)
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
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

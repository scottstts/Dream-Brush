//
//  CaptureView.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/5.
//

import SwiftUI

struct CaptureView: View {
    @State private var showingCaptureSession = false
    @State private var animationPhase: CGFloat = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) { // Main consistent spacing
                Spacer()

                // Hero & Features Group
                VStack(spacing: 32) {
                    HeroVisual(animationPhase: animationPhase)
                    
                    FeatureListView()
                }

                // Action Group
                VStack(spacing: 16) {
                    Text("Move slowly, avoid low light and high exposure")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    StartButton {
                        showingCaptureSession = true
                    }
                }
                
                Spacer()
                Spacer() // Extra spacer to push content slightly upwards visually
            }
            .navigationTitle("Capture")
            .onAppear {
                withAnimation(
                    .linear(duration: 4.0)
                    .repeatForever(autoreverses: false)
                ) {
                    animationPhase = .pi * 2
                }
            }
            .fullScreenCover(isPresented: $showingCaptureSession) {
                NavigationStack {
                    CaptureSessionView()
                }
            }
        }
    }
}

// MARK: - Subviews

private struct HeroVisual: View, Animatable {
    var animationPhase: CGFloat

    var animatableData: CGFloat {
        get { animationPhase }
        set { animationPhase = newValue }
    }

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let i = Double(index)
                let phase = Double(animationPhase)
                let ringOffset = sin(phase + i * 0.5) * (10 + i * 5)
                
                Circle()
                    .stroke(
                        Color.accentColor.opacity(0.15 - i * 0.04),
                        lineWidth: 1.5
                    )
                    .frame(
                        width: 140 + CGFloat(index) * 40,
                        height: 140 + CGFloat(index) * 40
                    )
                    .offset(x: CGFloat(ringOffset))
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.2),
                            Color.accentColor.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 130, height: 130)

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(height: 220)
    }
}

private struct FeatureListView: View {
    let features: [(icon: String, label: String)] = [
        ("cube", "Depth"),
        ("globe.americas", "World Map"),
        ("arrow.triangle.2.circlepath", "Relocalize")
    ]

    var body: some View {
        // Robust adaptive layout: Try single row, fall back to wrapped grid
        ViewThatFits(in: .horizontal) {
            // Option 1: Single line
            HStack(spacing: 8) {
                ForEach(features, id: \.label) { feature in
                    FeatureChip(icon: feature.icon, label: feature.label)
                }
            }
            
            // Option 2: Wrap if needed (centered grid)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    FeatureChip(icon: features[0].icon, label: features[0].label)
                    FeatureChip(icon: features[1].icon, label: features[1].label)
                }
                FeatureChip(icon: features[2].icon, label: features[2].label)
            }
        }
    }
}

private struct StartButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .symbolEffect(.pulse, options: .repeating)

                Text("Start Capture")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 6)
        }
        .padding(.horizontal, 24)
    }
}

private struct FeatureChip: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6).opacity(0.8))
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false) // Prevent text truncation
    }
}

#Preview {
    CaptureView()
}

//
//  CapturePlan.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/8.
//

import Foundation

struct CapturePlan: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    var slots: [CaptureSlot]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        slots: [CaptureSlot]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.slots = slots
    }
}

struct CaptureSlot: Codable, Identifiable {
    let id: UUID
    let title: String
    let instruction: String
    let yawDegrees: Float
    let isYawFree: Bool
    let pitchDegrees: Float?
    let rollDegrees: Float?
    let yawToleranceDegrees: Float
    let pitchToleranceDegrees: Float?
    let rollToleranceDegrees: Float?
    let translationOffsetMeters: Vector3
    let translationToleranceMeters: Float

    init(
        id: UUID = UUID(),
        title: String,
        instruction: String,
        yawDegrees: Float,
        isYawFree: Bool = false,
        pitchDegrees: Float? = nil,
        rollDegrees: Float? = nil,
        yawToleranceDegrees: Float,
        pitchToleranceDegrees: Float? = nil,
        rollToleranceDegrees: Float? = nil,
        translationOffsetMeters: Vector3 = .zero,
        translationToleranceMeters: Float
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.yawDegrees = yawDegrees
        self.isYawFree = isYawFree
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.yawToleranceDegrees = yawToleranceDegrees
        self.pitchToleranceDegrees = pitchToleranceDegrees
        self.rollToleranceDegrees = rollToleranceDegrees
        self.translationOffsetMeters = translationOffsetMeters
        self.translationToleranceMeters = translationToleranceMeters
    }
}

struct Vector3: Codable, Hashable {
    let x: Float
    let y: Float
    let z: Float

    static let zero = Vector3(x: 0, y: 0, z: 0)
}

extension CapturePlan {
    static func rotationOnlyDefault() -> CapturePlan {
        let yawTolerance: Float = 7
        let uprightTolerance: Float = 8
        let translationTolerance: Float = 0.18

        let slots = [
            CaptureSlot(
                title: "Start",
                instruction: "Face any wall. Keep the phone upright and steady.",
                yawDegrees: 0,
                isYawFree: true,
                pitchDegrees: 0,
                rollDegrees: 0,
                yawToleranceDegrees: yawTolerance,
                pitchToleranceDegrees: uprightTolerance,
                rollToleranceDegrees: uprightTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 2",
                instruction: "Turn 45° left or right and hold steady.",
                yawDegrees: 45,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 3",
                instruction: "Turn another 45° in the same direction.",
                yawDegrees: 90,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 4",
                instruction: "Turn another 45° in the same direction.",
                yawDegrees: 135,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 5",
                instruction: "Turn another 45° in the same direction.",
                yawDegrees: 180,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 6",
                instruction: "Turn another 45° in the same direction.",
                yawDegrees: 225,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 7",
                instruction: "Turn another 45° in the same direction.",
                yawDegrees: 270,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            ),
            CaptureSlot(
                title: "Slot 8",
                instruction: "Turn another 45° in the same direction.",
                yawDegrees: 315,
                yawToleranceDegrees: yawTolerance,
                translationToleranceMeters: translationTolerance
            )
        ]

        return CapturePlan(name: "Octants (8)", slots: slots)
    }
}

//
//  SimdExtensions.swift
//  DreamBrush
//
//  Created by Scott Sun on 2026/1/6.
//

import simd

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return matrix
    }
}

//
//  SplatAssetValidatorTests.swift
//  DreamBrushTests
//
//  Created by Scott Sun on 2026/1/6.
//

import Foundation
import Testing
@testable import DreamBrush

struct SplatAssetValidatorTests {
    @Test func parsePlyHeaderExtractsVertexCount() throws {
        let header = """
        ply
        format ascii 1.0
        element vertex 42
        property float x
        end_header
        """

        let data = try #require(header.data(using: .ascii))
        let info = try SplatAssetValidator.parsePlyHeader(from: data)

        #expect(info.vertexCount == 42)
        #expect(info.format?.contains("ascii") == true)
    }

    @Test func parsePlyHeaderRejectsMissingPlyLine() {
        let header = """
        format ascii 1.0
        element vertex 7
        end_header
        """

        let data = header.data(using: .ascii) ?? Data()
        #expect(throws: SplatAssetValidationError.self) {
            _ = try SplatAssetValidator.parsePlyHeader(from: data)
        }
    }

    @Test func parsePlyHeaderRequiresEndHeader() {
        let header = """
        ply
        format ascii 1.0
        element vertex 7
        """

        let data = header.data(using: .ascii) ?? Data()
        #expect(throws: SplatAssetValidationError.self) {
            _ = try SplatAssetValidator.parsePlyHeader(from: data)
        }
    }

    @Test func parsePlyHeaderIgnoresBinaryPayload() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex 3
        end_header
        """
        var data = (header.data(using: .ascii) ?? Data())
        data.append(contentsOf: [0x00, 0xFF, 0x10, 0x80])

        let info = try SplatAssetValidator.parsePlyHeader(from: data)
        #expect(info.vertexCount == 3)
        #expect(info.format?.contains("binary_little_endian") == true)
    }
}

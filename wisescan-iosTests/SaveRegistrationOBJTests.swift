import XCTest
import simd
@testable import wisescan_ios

/// Golden-fixture lock on `SaveRegistration.transformOBJ`'s output bytes.
///
/// The transform is a text rewrite of mesh.obj inside the registration bake's rollback window,
/// and its ghost-load inverse depends on the exact same formatting — a silent change to how a
/// vertex line is emitted corrupts meshes without any parse error. These fixtures pin the
/// observable contract: Swift's default Float description, single-space rejoining of v-line
/// components, verbatim passthrough of everything else, and separator/trailing-newline fidelity.
/// (`transformOBJ` sits outside SaveRegistration's RoomPlan-gated region, so this runs on the
/// simulator with no device.)
final class SaveRegistrationOBJTests: XCTestCase {

    private func transform(_ input: String, by m: simd_float4x4 = matrix_identity_float4x4) -> String {
        let out = SaveRegistration.transformOBJ(Data(input.utf8), by: m)
        return String(data: out, encoding: .utf8)!
    }

    func testIdentity_reformatsVertexLines_leavesOthersVerbatim() {
        // Identity is NOT a byte no-op: v-lines re-emit through Float description ("1" → "1.0")
        // and collapse internal runs of spaces; every other line passes through untouched.
        let input = """
        # comment  with  spaces
        v 1 2 3
        v  4  5  6
        vn 0 1 0
        f 1 2 3
        """
        let expected = """
        # comment  with  spaces
        v 1.0 2.0 3.0
        v 4.0 5.0 6.0
        vn 0 1 0
        f 1 2 3
        """
        XCTAssertEqual(transform(input), expected)
    }

    func testTranslation_movesCoordinates_andPreservesExtraComponents() {
        // Components past x/y/z (vertex colors) ride along untransformed, single-spaced.
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(10, -2, 0.5, 1)
        let input = "v 1 2 3 0.25 0.5 0.75\n"
        XCTAssertEqual(transform(input, by: m), "v 11.0 0.0 3.5 0.25 0.5 0.75\n")
    }

    func testUnparsableVertexLines_passThroughVerbatim() {
        // Short, non-numeric, and CRLF-tailed v-lines fail the Float parse and must not be touched.
        let input = "v 1 2\nv a b c\nv 1 2 3\r\nv1 2 3\n"
        XCTAssertEqual(transform(input), "v 1 2\nv a b c\nv 1 2 3\r\nv1 2 3\n")
    }

    func testNewlineFidelity() {
        // No trailing newline stays absent; a trailing newline stays single; blank lines survive.
        XCTAssertEqual(transform("v 1 2 3"), "v 1.0 2.0 3.0")
        XCTAssertEqual(transform("v 1 2 3\n"), "v 1.0 2.0 3.0\n")
        XCTAssertEqual(transform("a\n\nb"), "a\n\nb")
        XCTAssertEqual(transform(""), "")
    }

    func testNonUTF8Input_returnsInputUnchanged() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x80, 0xC3])
        XCTAssertEqual(SaveRegistration.transformOBJ(bytes, by: matrix_identity_float4x4), bytes)
    }

    func testRoundTrip_throughInverse_isStableAfterFirstPass() {
        // The ghost-load path applies the inverse of the bake. Floats lose bits in the round trip,
        // but a second forward+inverse pass over already-quantized output must be byte-stable —
        // that stability is what keeps repeated ghost load/undo cycles from walking the mesh.
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(0, 1, 0, 0)
        m.columns.1 = SIMD4<Float>(-1, 0, 0, 0)
        m.columns.3 = SIMD4<Float>(0.123, -4.56, 7.89, 1)
        let input = "v 1.5 -2.25 3.125\nv 0.1 0.2 0.3\nf 1 2 3\n"
        let once = SaveRegistration.transformOBJ(
            SaveRegistration.transformOBJ(Data(input.utf8), by: m), by: m.inverse)
        let twice = SaveRegistration.transformOBJ(
            SaveRegistration.transformOBJ(once, by: m), by: m.inverse)
        XCTAssertEqual(once, twice)
    }
}

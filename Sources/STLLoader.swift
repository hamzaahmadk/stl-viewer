import Foundation
import simd

struct STLMesh {
    /// xyz for every vertex (three per triangle), expressed relative to `center`
    /// so single-precision stays accurate even for models far from the origin.
    var positions: [Float]
    /// Bounds in the file's original coordinates.
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>

    var triangleCount: Int { positions.count / 9 }
    var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }
    var size: SIMD3<Float> { boundsMax - boundsMin }
}

enum STLError: LocalizedError {
    case noTriangles
    case truncated
    case tooLarge
    case outOfRange

    var errorDescription: String? {
        switch self {
        case .outOfRange: "The model's coordinates are too large to display."
        case .noTriangles: "No triangles found. This doesn't look like a valid STL file."
        case .truncated: "The file ends before all of its triangles do. It may be incomplete or corrupted."
        case .tooLarge: "The model is too large to load into GPU memory."
        }
    }
}

enum STLLoader {
    /// Largest bounding-box side we accept, in file units.
    private static let maxExtent: Float = 1e15

    static func load(url: URL) throws -> STLMesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var raw = isBinary(data) ? try binaryPositions(data) : asciiPositions(data)
        return try makeMesh(from: &raw)
    }

    // MARK: Format detection

    private static func binaryTriangleCount(_ data: Data) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) }
    }

    /// Binary files are 80 header bytes + a uint32 count + 50 bytes per triangle. Some binary
    /// files also start with "solid", so the exact size check has to come before the text check.
    /// Anything else that doesn't start with "solid" is treated as binary, so a truncated file
    /// gets a "file is incomplete" error rather than a confusing "no triangles".
    private static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        if data.count == 84 + 50 * binaryTriangleCount(data) { return true }
        return !data.prefix(5).elementsEqual("solid".utf8)
    }

    // MARK: Parsing

    private static func binaryPositions(_ data: Data) throws -> [Float] {
        let n = binaryTriangleCount(data)
        guard n > 0 else { throw STLError.noTriangles }
        guard data.count >= 84 + 50 * n else { throw STLError.truncated }

        var out = [Float](repeating: 0, count: n * 9)
        data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for t in 0..<n {
                    // Skip the 12-byte facet normal: shading is derived from the geometry,
                    // so bad normals in the file can't produce bad lighting.
                    memcpy(dst.baseAddress! + t * 36, src.baseAddress! + 84 + t * 50 + 12, 36)
                }
            }
        }
        return out
    }

    private static func asciiPositions(_ data: Data) -> [Float] {
        var bytes = [UInt8](data)
        bytes.append(0) // strtof needs a terminator
        var out = [Float]()
        out.reserveCapacity(bytes.count / 8)

        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let end = base + (buf.count - 1)
            var p = base
            while p < end, let hit = memmem(p, end - p, "vertex", 6) {
                var cursor = UnsafeRawPointer(hit).advanced(by: 6).assumingMemoryBound(to: CChar.self)
                var next: UnsafeMutablePointer<CChar>?
                for _ in 0..<3 {
                    out.append(strtof(cursor, &next))
                    cursor = UnsafePointer(next ?? UnsafeMutablePointer(mutating: cursor))
                }
                p = UnsafeRawPointer(cursor).assumingMemoryBound(to: UInt8.self)
            }
        }
        return out
    }

    // MARK: Mesh construction

    /// Drops triangles with non-finite coordinates, measures the bounds, and recentres the
    /// positions on the middle of the bounding box.
    private static func makeMesh(from positions: inout [Float]) throws -> STLMesh {
        let triangles = positions.count / 9
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var kept = 0

        positions.withUnsafeMutableBufferPointer { p in
            for t in 0..<triangles {
                let s = t * 9
                var finite = true
                for k in 0..<9 where !p[s + k].isFinite { finite = false; break }
                guard finite else { continue }
                if kept != s { for k in 0..<9 { p[kept + k] = p[s + k] } }
                for v in 0..<3 {
                    let q = SIMD3(p[kept + v * 3], p[kept + v * 3 + 1], p[kept + v * 3 + 2])
                    lo = pointwiseMin(lo, q)
                    hi = pointwiseMax(hi, q)
                }
                kept += 9
            }
        }
        guard kept > 0 else { throw STLError.noTriangles }
        positions.removeLast(positions.count - kept)

        // Single precision can't sensibly measure or draw models this big (lengths would overflow
        // to infinity), so refuse them instead of letting infinities spread through the renderer.
        let extent = hi - lo
        guard extent.x <= maxExtent, extent.y <= maxExtent, extent.z <= maxExtent else {
            throw STLError.outOfRange
        }

        let center = lo * 0.5 + hi * 0.5 // not (lo + hi) / 2, which can overflow
        positions.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: kept, by: 3) {
                p[i] -= center.x
                p[i + 1] -= center.y
                p[i + 2] -= center.z
            }
        }
        return STLMesh(positions: positions, boundsMin: lo, boundsMax: hi)
    }
}

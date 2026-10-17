import simd

// MARK: Matrices (right-handed, Metal clip space with z in 0...1)

func perspectiveRH(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let ys = 1 / tan(fovY * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return float4x4(columns: (
        SIMD4(xs, 0, 0, 0),
        SIMD4(0, ys, 0, 0),
        SIMD4(0, 0, zs, -1),
        SIMD4(0, 0, zs * near, 0)))
}

func orthographicRH(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> float4x4 {
    let zs = 1 / (near - far)
    return float4x4(columns: (
        SIMD4(1 / halfWidth, 0, 0, 0),
        SIMD4(0, 1 / halfHeight, 0, 0),
        SIMD4(0, 0, zs, 0),
        SIMD4(0, 0, near * zs, 1)))
}

func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
}

// MARK: Orbit camera (Z-up, like most CAD and slicer software)

enum StandardView {
    case home, front, back, left, right, top, bottom

    /// Camera azimuth and elevation in radians. Front looks along +Y from the -Y side.
    var angles: (azimuth: Float, elevation: Float) {
        let deg = Float.pi / 180
        switch self {
        case .home: return (-50 * deg, 28 * deg)
        case .front: return (-90 * deg, 0)
        case .back: return (90 * deg, 0)
        case .left: return (180 * deg, 0)
        case .right: return (0, 0)
        case .top: return (-90 * deg, OrbitCamera.maxElevation)
        case .bottom: return (-90 * deg, -OrbitCamera.maxElevation)
        }
    }
}

struct OrbitCamera {
    static let fovY: Float = 45 * .pi / 180
    static let worldUp = SIMD3<Float>(0, 0, 1)
    static let maxElevation: Float = .pi / 2 - 0.001

    var target = SIMD3<Float>.zero
    var distance: Float = 1
    var azimuth: Float = StandardView.home.angles.azimuth
    var elevation: Float = StandardView.home.angles.elevation
    var orthographic = false

    /// Unit vector from the target towards the eye.
    var direction: SIMD3<Float> {
        SIMD3(cos(elevation) * cos(azimuth), cos(elevation) * sin(azimuth), sin(elevation))
    }
    var right: SIMD3<Float> { normalize(cross(-direction, Self.worldUp)) }
    var up: SIMD3<Float> { cross(right, -direction) }

    mutating func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation = min(max(elevation + deltaElevation, -Self.maxElevation), Self.maxElevation)
    }

    /// Moves the target so the model follows the cursor by (dx, dy) points (y up).
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let worldPerPoint = 2 * distance * tan(Self.fovY / 2) / max(viewHeight, 1)
        target -= right * (dx * worldPerPoint) + up * (dy * worldPerPoint)
    }

    mutating func zoom(by factor: Float, limits: ClosedRange<Float>) {
        distance = min(max(distance * factor, limits.lowerBound), limits.upperBound)
    }

    /// Centres on the model (whose bounding box is centred on the origin) and backs off until
    /// every corner of the box fits the window from the current viewing angle.
    mutating func fit(halfExtents h: SIMD3<Float>, aspect: Float) {
        let tanY = tan(Self.fovY / 2)
        let tanX = tanY * aspect
        let (r, u, d) = (right, up, direction)
        var needed: Float = 0
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    let corner = SIMD3(sx * h.x, sy * h.y, sz * h.z)
                    let depthTowardEye = dot(corner, d)
                    needed = max(needed, depthTowardEye + max(abs(dot(corner, r)) / tanX, abs(dot(corner, u)) / tanY))
                }
            }
        }
        target = .zero
        distance = needed * 1.08
    }

    mutating func apply(_ view: StandardView) {
        (azimuth, elevation) = view.angles
    }
}

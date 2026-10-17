// Draws the app icon and writes a complete .iconset folder.
//   swiftc tools/make_icon.swift -o make_icon && ./make_icon AppIcon.iconset
// (tools/make_icon.sh does this and packages Resources/AppIcon.icns.)
import AppKit

// MARK: Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: nil)!
}

/// macOS icons are superellipses ("squircles"), not plain rounded rectangles.
func squircle(in r: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                        y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

// MARK: Isometric projection (Z up; +x runs down-right, +y runs down-left)

typealias V3 = (x: CGFloat, y: CGFloat, z: CGFloat)

let cubeScale: CGFloat = 275
let origin = CGPoint(x: 512, y: 548)

func project(_ p: V3) -> CGPoint {
    CGPoint(x: origin.x + (p.x - p.y) * 0.8660254 * cubeScale,
            y: origin.y + p.z * cubeScale - (p.x + p.y) * 0.5 * cubeScale)
}

func add(_ a: V3, _ b: V3, _ k: CGFloat = 1) -> V3 { (a.x + b.x * k, a.y + b.y * k, a.z + b.z * k) }

// MARK: The icon

func drawIcon(in ctx: CGContext, pixels: Int) {
    let simple = pixels <= 64 // drop fine detail that would just turn to mush
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(in: body)

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Drop shadow under the whole icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
    ctx.setFillColor(color(0x0B1124))
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Background: deep navy, lighter towards the top.
    ctx.drawLinearGradient(gradient([(0x24387A, 1), (0x0B1124, 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Glow where the cube sits.
    ctx.drawRadialGradient(gradient([(0x3D8BFF, 0.50), (0x3D8BFF, 0)]),
                           startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 430), endRadius: 470, options: [])

    // Floor grid under the cube, fading out with distance.
    if !simple {
        let floorZ: CGFloat = -0.5
        let extent: CGFloat = 2.6
        ctx.setLineWidth(2.6)
        func fadingLine(from a: V3, to b: V3) {
            let n = 48
            for i in 0..<n {
                let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n)
                let p0 = (x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0, z: floorZ)
                let p1 = (x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1, z: floorZ)
                let mid = hypot((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)
                let alpha = 0.42 * pow(max(0, 1 - mid / extent), 1.4)
                guard alpha > 0.005 else { continue }
                ctx.setStrokeColor(color(0x8EC0FF, alpha))
                ctx.move(to: project(p0))
                ctx.addLine(to: project(p1))
                ctx.strokePath()
            }
        }
        var k: CGFloat = -extent
        while k <= extent + 0.001 {
            fadingLine(from: (-extent, k, floorZ), to: (extent, k, floorZ))
            fadingLine(from: (k, -extent, floorZ), to: (k, extent, floorZ))
            k += 0.5
        }
    }

    // Cube: three visible faces, each a 2x2 patch of triangulated quads.
    struct Face { let o: V3, u: V3, v: V3, from: UInt32, to: UInt32 }
    let faces = [
        Face(o: (-0.5, -0.5, 0.5), u: (1, 0, 0), v: (0, 1, 0), from: 0xCFE2FA, to: 0x8FB4E8),   // top
        Face(o: (-0.5, 0.5, 0.5), u: (1, 0, 0), v: (0, 0, -1), from: 0x7FA2D6, to: 0x4D70A8),   // left
        Face(o: (0.5, -0.5, 0.5), u: (0, 1, 0), v: (0, 0, -1), from: 0x4F6FA3, to: 0x283F6B),   // right
    ]
    let cells = simple ? 1 : 2

    for f in faces {
        let corners = [f.o, add(f.o, f.u), add(add(f.o, f.u), f.v), add(f.o, f.v)].map(project)

        ctx.saveGState()
        ctx.move(to: corners[0])
        corners.dropFirst().forEach { ctx.addLine(to: $0) }
        ctx.closePath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(f.from, 1), (f.to, 1)]),
                               start: corners[0], end: corners[2],
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Triangulation: alternating diagonals so the mesh reads as a mesh.
        ctx.setStrokeColor(color(0xFFFFFF, 0.34))
        ctx.setLineWidth(simple ? 5 : 3.6)
        let step = 1 / CGFloat(cells)
        func at(_ i: Int, _ j: Int) -> CGPoint {
            project(add(add(f.o, f.u, CGFloat(i) * step), f.v, CGFloat(j) * step))
        }
        for i in 0..<cells {
            for j in 0..<cells {
                let (a, b) = (i + j) % 2 == 0 ? (at(i, j), at(i + 1, j + 1)) : (at(i + 1, j), at(i, j + 1))
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }
        }
        if cells > 1 {
            for i in 1..<cells {
                ctx.move(to: at(i, 0)); ctx.addLine(to: at(i, cells)); ctx.strokePath()
                ctx.move(to: at(0, i)); ctx.addLine(to: at(cells, i)); ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    // Crisp edges: the silhouette and the three edges meeting at the front corner.
    let A = project((-0.5, -0.5, 0.5)), B = project((0.5, -0.5, 0.5)), C = project((0.5, 0.5, 0.5))
    let D = project((-0.5, 0.5, 0.5)), E = project((0.5, 0.5, -0.5))
    let F = project((0.5, -0.5, -0.5)), G = project((-0.5, 0.5, -0.5))

    ctx.setStrokeColor(color(0xFFFFFF, 0.62))
    ctx.setLineWidth(simple ? 6 : 5)
    ctx.move(to: A)
    [B, F, E, G, D].forEach { ctx.addLine(to: $0) }
    ctx.closePath()
    ctx.strokePath()

    ctx.setStrokeColor(color(0xFFFFFF, 0.50))
    for p in [B, D, E] { ctx.move(to: C); ctx.addLine(to: p); ctx.strokePath() }

    // Glowing vertices.
    if !simple {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22, color: color(0x7FC1FF, 1))
        ctx.setFillColor(color(0xFFFFFF, 0.97))
        for p in [A, B, C, D, E, F, G] {
            ctx.fillEllipse(in: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
        }
        ctx.restoreGState()
    }

    // Soft gloss across the top of the icon.
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.14), (0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])

    // Thin inner rim.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: Output

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context.cgContext, pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_icon <output .iconset folder>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try png(pixels: pixels).write(to: outDir.appendingPathComponent("\(name).png"))
}
print("Wrote \(sizes.count) images to \(outDir.path)")

import AppKit
import MetalKit
import simd

// Shading is derived from screen-space derivatives of the position, so every face is flat-shaded
// from its real geometry. That makes the viewer immune to missing or flipped normals in the file,
// and halves the vertex memory. Wireframe uses per-corner barycentrics in the same pass.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4x4 view;
    float4   color;
    float4   params;   // x: orthographic, y: wireframe overlay
};

struct MeshOut {
    float4 position [[position]];
    float3 viewPos;
    float3 bary;
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device packed_float3 *positions [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    float3 p = positions[vid];
    uint corner = vid % 3;
    MeshOut out;
    out.position = u.viewProj * float4(p, 1.0);
    out.viewPos = (u.view * float4(p, 1.0)).xyz;
    out.bary = float3(corner == 0 ? 1.0 : 0.0, corner == 1 ? 1.0 : 0.0, corner == 2 ? 1.0 : 0.0);
    return out;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 toEye = u.params.x > 0.5 ? float3(0.0, 0.0, 1.0) : normalize(-in.viewPos);
    float3 c = cross(dfdx(in.viewPos), dfdy(in.viewPos));
    float len = length(c);
    float3 n = len > 0.0 ? c / len : toEye;
    if (dot(n, toEye) < 0.0) n = -n;

    float3 key  = normalize(float3(-0.5, 0.7, 0.8));
    float3 fill = normalize(float3(0.8, -0.3, 0.4));
    float diffuse = 0.55 * max(dot(n, key), 0.0) + 0.22 * max(dot(n, fill), 0.0);
    float ambient = 0.30 + 0.12 * n.y;
    float spec = 0.22 * pow(max(dot(n, normalize(key + toEye)), 0.0), 40.0);
    float3 lit = u.color.rgb * (ambient + diffuse) + spec;

    if (u.params.y > 0.5) {
        float3 w = fwidth(in.bary) * 1.2 + 1e-6;
        float3 e = smoothstep(float3(0.0), w, in.bary);
        float edge = 1.0 - min(min(e.x, e.y), e.z);
        lit = mix(lit, float3(0.02), edge * 0.85);
    }
    return float4(lit, 1.0);
}

struct GridOut { float4 position [[position]]; };

vertex GridOut grid_vertex(uint vid [[vertex_id]],
                           const device packed_float3 *positions [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    GridOut out;
    out.position = u.viewProj * float4(positions[vid], 1.0);
    return out;
}

fragment float4 grid_fragment(GridOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    return u.color;
}
"""

private struct Uniforms {
    var viewProj = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var color = SIMD4<Float>(repeating: 1)
    var params = SIMD4<Float>(repeating: 0)
}

private let msaaSampleCount = 4

/// Device, queue and pipelines are shared by every window.
private final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let meshPipeline: MTLRenderPipelineState
    let gridPipeline: MTLRenderPipelineState
    let meshDepth: MTLDepthStencilState
    let gridDepth: MTLDepthStencilState

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac.")
        }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: nil) }
        catch { fatalError("Shader compile failed: \(error)") }

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = msaaSampleCount
            d.depthAttachmentPixelFormat = .depth32Float
            let color = d.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            if blended {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: d) }
            catch { fatalError("Pipeline creation failed: \(error)") }
        }
        meshPipeline = pipeline("mesh_vertex", "mesh_fragment", blended: false)
        gridPipeline = pipeline("grid_vertex", "grid_fragment", blended: true)

        func depth(write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .less
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        meshDepth = depth(write: true)
        gridDepth = depth(write: false)
    }
}

final class ViewerView: MTKView, MTKViewDelegate {
    private let metal = MetalContext.shared

    private var meshBuffer: MTLBuffer?
    private var vertexCount = 0
    private var gridBuffer: MTLBuffer?
    private var gridVertexCount = 0
    private var radius: Float = 1                 // bounding-sphere radius
    private var halfExtents = SIMD3<Float>(repeating: 1)
    private var camera = OrbitCamera()
    private var lastMouse = NSPoint.zero

    private(set) var gridStep: Float = 0 // 0 when there is no grid
    private(set) var showGrid = true
    private(set) var showWireframe = false

    /// Called with .stl files dropped onto the view.
    var onDropFiles: (([URL]) -> Void)?

    init() {
        super.init(frame: .zero, device: metal.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = msaaSampleCount
        isPaused = true
        enableSetNeedsDisplay = true // draw on demand: idle viewer costs nothing
        delegate = self
        registerForDraggedTypes([.fileURL])
        applyAppearance()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Model

    func setMesh(_ mesh: STLMesh) throws {
        let buffer = mesh.positions.withUnsafeBytes {
            metal.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        guard let buffer else { throw STLError.tooLarge }
        meshBuffer = buffer
        vertexCount = mesh.positions.count / 3
        halfExtents = mesh.size / 2
        radius = max(simd_length(halfExtents), 1e-6)
        buildGrid(for: mesh)
        resetView(nil)
    }

    /// A ground grid under the model, with lines at multiples of a "nice" step in file coordinates.
    /// Skipped (`gridStep` stays 0) when the model sits so far from the origin, relative to its
    /// size, that single precision couldn't tell the lines apart anyway.
    private func buildGrid(for mesh: STLMesh) {
        gridBuffer = nil
        gridVertexCount = 0
        gridStep = 0

        // Double throughout, and checked Int conversions: crafted files can hold coordinates
        // where Float overflows, and an unchecked Int(Float) would crash the app.
        let lo = SIMD3<Double>(mesh.boundsMin), hi = SIMD3<Double>(mesh.boundsMax)
        let size = hi - lo
        let c = lo * 0.5 + hi * 0.5
        let span = max(size.x, size.y, Double(radius) * 0.2)
        let step = Self.niceStep(span / 8)
        let half = max(step * (span * 0.75 / step).rounded(.up), step * 2)

        func lineIndices(around centre: Double) -> ClosedRange<Int>? {
            guard let first = Int(exactly: ((centre - half) / step).rounded(.up)),
                  let last = Int(exactly: ((centre + half) / step).rounded(.down)),
                  abs(first) < 1_000_000_000_000, abs(last) < 1_000_000_000_000,
                  first <= last, last - first <= 500 else { return nil }
            return first...last
        }
        guard let xs = lineIndices(around: c.x), let ys = lineIndices(around: c.y) else { return }

        let z = Float(-size.z / 2 - Double(radius) * 0.002) // nudged down so it never z-fights the model's base
        let h = Float(half)
        var lines = [Float]()
        for k in xs {
            let x = Float(Double(k) * step - c.x)
            lines += [x, -h, z, x, h, z]
        }
        for k in ys {
            let y = Float(Double(k) * step - c.y)
            lines += [-h, y, z, h, y, z]
        }
        gridVertexCount = lines.count / 3
        gridBuffer = lines.withUnsafeBytes {
            metal.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        gridStep = Float(step)
    }

    private static func niceStep(_ x: Double) -> Double {
        let magnitude = pow(10, floor(log10(max(x, 1e-300))))
        let f = x / magnitude
        return (f < 1.5 ? 1.0 : f < 3.5 ? 2.0 : f < 7.5 ? 5.0 : 10.0) * magnitude
    }

    // MARK: Drawing

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func applyAppearance() {
        clearColor = isDark
            ? MTLClearColor(red: 0.115, green: 0.125, blue: 0.145, alpha: 1)
            : MTLClearColor(red: 0.930, green: 0.936, blue: 0.945, alpha: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let commands = metal.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let aspect = Float(drawableSize.width / drawableSize.height)
        let cam = camera
        let sceneRadius = radius + simd_length(cam.target)
        // An orthographic camera has no perspective to lose, so keep the eye clear of the model.
        let eyeDistance = cam.orthographic ? max(cam.distance, sceneRadius * 2.5) : cam.distance
        let far = eyeDistance + sceneRadius * 2
        let near = max(eyeDistance - sceneRadius * 2, far * 1e-4)

        let eye = cam.target + cam.direction * eyeDistance
        let viewMatrix = lookAtRH(eye: eye, center: cam.target, up: OrbitCamera.worldUp)
        let projection: float4x4
        if cam.orthographic {
            let h = cam.distance * tan(OrbitCamera.fovY / 2)
            projection = orthographicRH(halfWidth: h * aspect, halfHeight: h, near: near, far: far)
        } else {
            projection = perspectiveRH(fovY: OrbitCamera.fovY, aspect: aspect, near: near, far: far)
        }

        var uniforms = Uniforms(viewProj: projection * viewMatrix, view: viewMatrix)
        let stride = MemoryLayout<Uniforms>.stride

        if showGrid, let gridBuffer {
            uniforms.color = isDark ? SIMD4(1, 1, 1, 0.13) : SIMD4(0, 0, 0, 0.14)
            encoder.setRenderPipelineState(metal.gridPipeline)
            encoder.setDepthStencilState(metal.gridDepth)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }

        if let meshBuffer {
            uniforms.color = SIMD4(0.55, 0.67, 0.82, 1)
            uniforms.params = SIMD4(cam.orthographic ? 1 : 0, showWireframe ? 1 : 0, 0, 0)
            encoder.setRenderPipelineState(metal.meshPipeline)
            encoder.setDepthStencilState(metal.meshDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Mouse, trackpad, keyboard

    private var distanceLimits: ClosedRange<Float> { (radius * 0.01)...(radius * 100) }
    private var aspect: Float { Float(bounds.width / max(bounds.height, 1)) }

    private func mouseDelta(_ event: NSEvent) -> (dx: Float, dy: Float) {
        let p = event.locationInWindow
        defer { lastMouse = p }
        return (Float(p.x - lastMouse.x), Float(p.y - lastMouse.y))
    }

    private func orbit(dx: Float, dy: Float) {
        // Dragging right turns the model to the right; dragging up tips its top away.
        camera.orbit(deltaAzimuth: -dx * 0.01, deltaElevation: -dy * 0.01)
        needsDisplay = true
    }

    private func pan(dx: Float, dy: Float) {
        camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
        needsDisplay = true
    }

    private func zoom(_ factor: Float) {
        camera.zoom(by: factor, limits: distanceLimits)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        lastMouse = event.locationInWindow
        if event.clickCount == 2 { zoomToFit(nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        let d = mouseDelta(event)
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            pan(dx: d.dx, dy: d.dy)
        } else {
            orbit(dx: d.dx, dy: d.dy)
        }
    }

    override func rightMouseDown(with event: NSEvent) { lastMouse = event.locationInWindow }
    override func rightMouseDragged(with event: NSEvent) { let d = mouseDelta(event); pan(dx: d.dx, dy: d.dy) }
    override func otherMouseDown(with event: NSEvent) { lastMouse = event.locationInWindow }
    override func otherMouseDragged(with event: NSEvent) { let d = mouseDelta(event); pan(dx: d.dx, dy: d.dy) }

    override func scrollWheel(with event: NSEvent) {
        let dy = Float(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas {
            zoom(pow(0.9, min(max(dy, -10), 10)))            // mouse wheel
        } else if event.modifierFlags.contains(.command) {
            zoom(pow(0.99, min(max(dy, -50), 50)))           // ⌘ + two-finger scroll
        } else {
            // Two-finger scroll: the model follows the fingers.
            pan(dx: Float(event.scrollingDeltaX), dy: -dy)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(1 / max(1 + Float(event.magnification), 0.1))
    }

    override func keyDown(with event: NSEvent) {
        let step: Float = 0.2
        switch event.specialKey {
        case .leftArrow: orbit(dx: -step / 0.01, dy: 0)
        case .rightArrow: orbit(dx: step / 0.01, dy: 0)
        case .upArrow: orbit(dx: 0, dy: step / 0.01)
        case .downArrow: orbit(dx: 0, dy: -step / 0.01)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drag and drop

    private func stlURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "stl" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        stlURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = stlURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func zoomToFit(_ sender: Any?) {
        camera.fit(halfExtents: halfExtents, aspect: aspect)
        needsDisplay = true
    }

    @objc func resetView(_ sender: Any?) {
        camera.apply(.home)
        zoomToFit(nil)
    }

    private func show(_ view: StandardView) {
        camera.apply(view)
        zoomToFit(nil)
    }

    @objc func viewFront(_ sender: Any?) { show(.front) }
    @objc func viewBack(_ sender: Any?) { show(.back) }
    @objc func viewLeft(_ sender: Any?) { show(.left) }
    @objc func viewRight(_ sender: Any?) { show(.right) }
    @objc func viewTop(_ sender: Any?) { show(.top) }
    @objc func viewBottom(_ sender: Any?) { show(.bottom) }

    @objc func zoomIn(_ sender: Any?) { zoom(0.8) }
    @objc func zoomOut(_ sender: Any?) { zoom(1.25) }

    @objc func toggleWireframe(_ sender: Any?) { showWireframe.toggle(); needsDisplay = true }
    @objc func toggleGrid(_ sender: Any?) { showGrid.toggle(); needsDisplay = true }
    @objc func toggleProjection(_ sender: Any?) { camera.orthographic.toggle(); needsDisplay = true }
}

extension ViewerView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleWireframe(_:)): item.state = showWireframe ? .on : .off
        case #selector(toggleGrid(_:)): item.state = showGrid ? .on : .off
        case #selector(toggleProjection(_:)): item.state = camera.orthographic ? .on : .off
        default: break
        }
        return meshBuffer != nil
    }
}

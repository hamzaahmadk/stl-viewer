import AppKit

final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let url: URL
    var onClose: ((ViewerWindowController) -> Void)?

    private let viewer = ViewerView()
    private let infoLabel = ViewerWindowController.makeLabel(size: 11, color: .secondaryLabelColor)
    private let hintLabel = ViewerWindowController.makeLabel(size: 11, color: .tertiaryLabelColor)
    private let spinner = NSProgressIndicator()

    init(url: URL, onOpenFiles: @escaping ([URL]) -> Void) {
        self.url = url
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = url.lastPathComponent
        window.representedURL = url
        window.contentMinSize = NSSize(width: 360, height: 280)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContent()
        window.makeFirstResponder(viewer)

        viewer.onDropFiles = onOpenFiles
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) { onClose?(self) }

    // MARK: Layout

    private static func makeLabel(size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeContent() -> NSView {
        let content = NSView()
        hintLabel.stringValue = "Drag to orbit  ·  Two-finger scroll or ⌥-drag to pan  ·  Pinch or wheel to zoom  ·  F to fit"
        hintLabel.alignment = .right
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false

        for view in [viewer, infoLabel, hintLabel, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            viewer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewer.topAnchor.constraint(equalTo: content.topAnchor),
            viewer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            infoLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            hintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: infoLabel.trailingAnchor, constant: 16),

            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        return content
    }

    // MARK: Loading

    private func load() {
        spinner.startAnimation(nil)
        let url = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try STLLoader.load(url: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                do {
                    let mesh = try result.get()
                    try self.viewer.setMesh(mesh)
                    self.infoLabel.stringValue = self.describe(mesh)
                } catch {
                    self.infoLabel.textColor = .systemRed
                    self.infoLabel.stringValue = "Couldn't open this file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func describe(_ mesh: STLMesh) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        func format<T: BinaryFloatingPoint>(_ value: T) -> String {
            formatter.string(from: NSNumber(value: Double(value))) ?? "?"
        }
        let triangles = formatter.string(from: NSNumber(value: mesh.triangleCount)) ?? "?"
        let size = mesh.size
        let grid = viewer.gridStep > 0 ? "  ·  grid \(format(viewer.gridStep))" : ""
        return "\(triangles) triangles  ·  \(format(size.x)) × \(format(size.y)) × \(format(size.z))\(grid)"
    }
}

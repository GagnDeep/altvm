import AppKit
import Virtualization

/// A native window hosting a running VM's display (Retina, live resize, system-key capture).
@MainActor
public final class VMWindowController: NSWindowController, NSWindowDelegate {
    public let runner: VMRunner
    private let vmView = VZVirtualMachineView()
    public var onClose: (() -> Void)?

    public init(runner: VMRunner) {
        self.runner = runner
        let spec = runner.spec
        let scale = max(1, CGFloat(spec.display.pixelsPerInch) / 72)
        let size = NSSize(width: CGFloat(spec.display.width) / scale * 1.0, height: CGFloat(spec.display.height) / scale * 1.0)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = spec.name
        window.subtitle = "\(spec.os.displayName) · \(spec.cpus) vCPU · \(spec.memoryMiB / 1024) GB"
        window.tabbingMode = .preferred
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self
        vmView.virtualMachine = runner.vm
        vmView.capturesSystemKeys = true
        vmView.automaticallyReconfiguresDisplay = spec.display.autoResize
        window.contentView = vmView
        window.center()
        window.setFrameAutosaveName("AltVM-\(spec.name)")
    }

    required init?(coder: NSCoder) { fatalError() }

    public func refreshMachine() { vmView.virtualMachine = runner.vm }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard runner.state == .running || runner.state == .paused else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(runner.spec.name)” is still running"
        alert.informativeText = "Suspend saves everything exactly as it is and resumes instantly next time."
        alert.addButton(withTitle: "Suspend")
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { try? await runner.suspend() }
        case .alertSecondButtonReturn: Task { try? await runner.stop() }
        default: return false
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) { onClose?() }
}

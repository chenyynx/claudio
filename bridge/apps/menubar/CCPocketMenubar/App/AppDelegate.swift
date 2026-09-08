import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let appViewModel = AppViewModel()

    /// Monitor for clicks outside the panel to dismiss it
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        parseMockDoctorArgument()
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = Self.createMenuBarIcon()
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Create a borderless, floating panel
        let contentView = NSHostingView(
            rootView: PopoverContentView(viewModel: appViewModel)
        )

        let panelSize = NSSize(width: 380, height: 500)

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false

        // Glass effect handles corner rounding; ensure layer is available
        panel.contentView?.wantsLayer = true
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Position the panel below the status bar button, right-aligned
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let panelWidth = panel.frame.width
        let x = screenRect.midX - panelWidth / 2
        let y = screenRect.minY - panel.frame.height - 4

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        // Monitor for outside clicks to dismiss
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel.orderOut(nil)

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Mock Doctor (DEBUG only)

    #if DEBUG
    private func parseMockDoctorArgument() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-mock-doctor"),
              flagIndex + 1 < args.count,
              let scenario = MockDoctorScenario(rawValue: args[flagIndex + 1]) else {
            return
        }

        // Reset onboarding so the user sees the full first-run experience
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        appViewModel.hasCompletedOnboarding = false

        // Inject mock scenario — doctorVM is created in PopoverContentView,
        // so we store it in UserDefaults for the view to pick up
        UserDefaults.standard.set(scenario.rawValue, forKey: "mockDoctorScenario")
    }
    #endif

    // MARK: - Menu Bar Icon (Drawn in code)

    /// Create "cc" logo icon for the menu bar. Drawn programmatically using strokes 
    /// with rounded caps to perfectly match the aesthetic of the CC Pocket logo.
    private static func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            
            NSColor.black.setStroke()
            
            let thickness: CGFloat = 2.16
            let radius: CGFloat = 4.5
            let cy: CGFloat = 9.0
            let gapHalf: CGFloat = 40.4 // Degrees
            
            // Left C
            let leftC = NSBezierPath()
            leftC.lineWidth = thickness
            leftC.lineCapStyle = .round
            leftC.appendArc(
                withCenter: NSPoint(x: 7.75, y: cy),
                radius: radius,
                startAngle: gapHalf,
                endAngle: -gapHalf,
                clockwise: false
            )
            leftC.stroke()
            
            // Right C
            let rightC = NSBezierPath()
            rightC.lineWidth = thickness
            rightC.lineCapStyle = .round
            rightC.appendArc(
                withCenter: NSPoint(x: 11.35, y: cy),
                radius: radius,
                startAngle: gapHalf,
                endAngle: -gapHalf,
                clockwise: false
            )
            rightC.stroke()
            
            return true
        }
        image.isTemplate = true
        return image
    }
}

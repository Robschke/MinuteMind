// Purpose: Floating NSPanel that hosts the Task Commander overlay — quick task entry + open task list.
// Dependencies: AppKit (NSPanel, NSVisualEffectView, NSHostingView), TaskCommanderView,
//               Sources/App/ViewModels/AppViewModel.swift
// Used by: Sources/App/MinuteMindApp.swift (AppDelegate hotkey handler)
// Notes: Uses NSPanel for floating behavior and key-window support. A separate full-screen
//        dimming window sits behind the panel to create the modal overlay effect.

import AppKit
import SwiftUI

@MainActor
final class TaskCommanderController {

    private var panel: NSPanel?
    private var dimmingWindow: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private weak var viewModel: AppViewModel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        guard let viewModel else { return }

        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)

        if panel == nil {
            createPanel(viewModel: viewModel)
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let panel, let screen else { return }

        // Show dimming window first
        showDimmingWindow(on: screen)

        // Center panel on screen
        let panelWidth: CGFloat = 560
        let panelHeight: CGFloat = 500
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.midY - panelHeight / 2
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func dismiss() {
        panel?.orderOut(nil)
        dimmingWindow?.orderOut(nil)
    }

    // MARK: - Private

    private func createPanel(viewModel: AppViewModel) {
        let panel = TaskCommanderNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 340)

        // Set dismiss callback
        panel.onClose = { [weak self] in
            self?.dismiss()
        }

        // Visual effect background for glass look
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        let contentView = TaskCommanderView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: AnyView(contentView))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.addSubview(visualEffect)
        container.addSubview(hosting)

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: container.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
        self.panel = panel
        self.hostingView = hosting
    }

    private func showDimmingWindow(on screen: NSScreen) {
        if dimmingWindow == nil {
            let dimWindow = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            dimWindow.backgroundColor = NSColor.black.withAlphaComponent(0.25)
            dimWindow.isOpaque = false
            dimWindow.hasShadow = false
            dimWindow.level = .floating - 1
            dimWindow.ignoresMouseEvents = false
            dimWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Click on dim to dismiss
            let clickView = DimmingClickView { [weak self] in
                self?.dismiss()
            }
            clickView.frame = screen.frame
            dimWindow.contentView = clickView

            self.dimmingWindow = dimWindow
        }

        dimmingWindow?.setFrame(screen.frame, display: true)
        dimmingWindow?.orderFront(nil)
    }
}

// MARK: - Custom NSPanel Subclass

private class TaskCommanderNSPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func close() {
        onClose?()
    }
}

// MARK: - Dimming Click View

private class DimmingClickView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}

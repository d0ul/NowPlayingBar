import AppKit
import SwiftUI
import ServiceManagement
import CoreImage
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel!
    private var clickOutsideMonitor: Any?
    private let model = NowPlayingModel()
    private var contentHostView: NSView!

    private var lastTitle: String?
    private var lastAlbum: String?
    private var lastArtwork: NSImage?
    private var lastIsPlaying = false

    private let panelSize = NSSize(width: 300, height: 214)
    private let cornerRadius: CGFloat = 20
    private let screenMargin = NSSize(width: 12, height: 8)

    private let appearBlurStart: CGFloat = 26
    private let disappearBlurEnd: CGFloat = 18

    private let statusIconSize = NSSize(width: 18, height: 18)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        DiscordRPC.shared.isEnabled = AppSettings.isDiscordRPCEnabled

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = fallbackIcon(isPlaying: false)
        item.button?.imagePosition = .imageLeading
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let hosting = NSHostingController(rootView: NowPlayingView(model: model))
        hosting.view.frame = NSRect(origin: .zero, size: panelSize)
        hosting.view.wantsLayer = true
        contentHostView = hosting.view

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: panelSize))
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting.view
            panel.contentView = glass
        } else {
            let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
            visualEffect.material = .popover
            visualEffect.state = .active
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = true
            visualEffect.addSubview(hosting.view)
            panel.contentView = visualEffect
        }

        MediaRemote.shared.fetchInfo { [weak self] np in self?.apply(np) }
        MediaRemote.shared.register { [weak self] np in self?.apply(np) }
    }

    private func apply(_ np: NowPlaying?) {
        model.update(np)
        lastTitle = np?.title
        lastAlbum = np?.album
        lastArtwork = model.artwork
        lastIsPlaying = np?.isPlaying ?? false
        updateStatusIcon(title: lastTitle, album: lastAlbum, artwork: lastArtwork, isPlaying: lastIsPlaying)
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let displayModeItem = NSMenuItem(
            title: String(localized: "menu.displayMode.title", defaultValue: "Display Mode"),
            action: nil,
            keyEquivalent: ""
        )
        displayModeItem.submenu = makeDisplayModeSubmenu()
        menu.addItem(displayModeItem)


        let discordItem = NSMenuItem(
            title: String(localized: "menu.discord.title", defaultValue: "Use Discord RPC"),
            action: #selector(toggleDiscordRPC),
            keyEquivalent: ""
        )
        discordItem.target = self
        discordItem.state = AppSettings.isDiscordRPCEnabled ? .on : .off
        menu.addItem(discordItem)

        let loginItem = NSMenuItem(
            title: String(localized: "menu.launchAtLogin.title", defaultValue: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "menu.quit.title", defaultValue: "Quit NowPlayingBar"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = symbolImage("xmark.rectangle")
        menu.addItem(quitItem)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeDisplayModeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let current = AppSettings.displayMode
        for mode in MenuBarDisplayMode.allCases {
            let menuItem = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectDisplayMode(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = mode.rawValue
            menuItem.state = (mode == current) ? .on : .off
            submenu.addItem(menuItem)
        }
        return submenu
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MenuBarDisplayMode(rawValue: raw) else { return }
        AppSettings.displayMode = mode
        updateStatusIcon(title: lastTitle, album: lastAlbum, artwork: lastArtwork, isPlaying: lastIsPlaying)
    }

    @objc private func toggleDiscordRPC() {
        let newValue = !AppSettings.isDiscordRPCEnabled
        AppSettings.isDiscordRPCEnabled = newValue
        DiscordRPC.shared.isEnabled = newValue
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            FileHandle.standardError.write("Failed to toggle launch at login: \(error)\n".data(using: .utf8)!)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusIcon(title: String?, album: String?, artwork: NSImage?, isPlaying: Bool) {
        let mode = AppSettings.displayMode
        let displayText = mode.text(title: title, album: album)
        item.button?.toolTip = title
        item.button?.imagePosition = .imageLeading
        item.button?.title = String(displayText.prefix(24))

        if mode == .titleOnly {
            item.button?.image = nil
        } else {
            item.button?.image = artwork.map(makeArtworkIcon) ?? fallbackIcon(isPlaying: isPlaying)
        }
    }

    private func makeArtworkIcon(from artwork: NSImage) -> NSImage {
        let icon = NSImage(size: statusIconSize)
        icon.lockFocus()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: statusIconSize), xRadius: 4, yRadius: 4).addClip()
        artwork.draw(in: NSRect(origin: .zero, size: statusIconSize), from: sourceRectForAspectFill(of: artwork), operation: .sourceOver, fraction: 1.0)
        icon.unlockFocus()
        icon.isTemplate = false
        return icon
    }

    private func sourceRectForAspectFill(of image: NSImage) -> NSRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return NSRect(origin: .zero, size: size)
        }
        let side = min(size.width, size.height)
        let x = (size.width - side) / 2
        let y = (size.height - side) / 2
        return NSRect(x: x, y: y, width: side, height: side)
    }

    private func fallbackIcon(isPlaying: Bool) -> NSImage {
        let symbolName = isPlaying ? "waveform" : "play.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage(size: statusIconSize)
    }

    private func toggle() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let finalX = screenFrame.maxX - panelSize.width - screenMargin.width
        let y = screenFrame.maxY - panelSize.height - screenMargin.height
        let finalFrame = NSRect(x: finalX, y: y, width: panelSize.width, height: panelSize.height)

        panel.setFrame(finalFrame, display: false)
        panel.alphaValue = 0

        let duration = 0.32
        if let layer = contentHostView.layer {
            setBlurRadius(appearBlurStart, on: layer, animated: false, duration: 0, timing: .init(name: .linear))
            setBlurRadius(0, on: layer, animated: true, duration: duration, timing: CAMediaTimingFunction(name: .easeOut))
        }

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }

        let duration = 0.22

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })

        if let layer = contentHostView.layer {
            setBlurRadius(disappearBlurEnd, on: layer, animated: true, duration: duration, timing: CAMediaTimingFunction(name: .easeIn))
        }
    }

    private func setBlurRadius(
        _ radius: CGFloat,
        on layer: CALayer,
        animated: Bool,
        duration: TimeInterval,
        timing: CAMediaTimingFunction,
        completion: (() -> Void)? = nil
    ) {
        if layer.filters == nil {
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.name = "blur"
            blur?.setValue(0, forKey: "inputRadius")
            layer.filters = blur.map { [$0] }
        }

        guard animated else {
            layer.setValue(radius, forKeyPath: "filters.blur.inputRadius")
            completion?()
            return
        }

        let currentRadius = layer.value(forKeyPath: "filters.blur.inputRadius") as? CGFloat ?? 0

        let anim = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        anim.fromValue = currentRadius
        anim.toValue = radius
        anim.duration = duration
        anim.timingFunction = timing
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(anim, forKey: "blurRadius")
        layer.setValue(radius, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
    }
}

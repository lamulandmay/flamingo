import AppKit
import FlamingoCore

/// Flamingo's window onto the link: the six digits while pairing, then which Capybara it's
/// paired with and whether they're connected. Plain AppKit, so FlamingoLink builds without
/// Xcode; the colours are Flamingo's tokens (FlamingoDesign/Theme.swift).
@MainActor
public final class CapybaraPanel: NSObject, NSWindowDelegate {
    let link: CapybaraLink
    private var panel: NSPanel?
    private let mark = LinkMarkView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    private let title = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "Pair", target: nil, action: nil)
    private let secondary = NSButton(title: "Cancel", target: nil, action: nil)
    private var wasPairing = false

    static let accent = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0x7A / 255, blue: 0x88 / 255, alpha: 1)
                                                          : NSColor(srgbRed: 0xD2 / 255, green: 0x3B / 255, blue: 0x57 / 255, alpha: 1)
    }

    public init(link: CapybaraLink) {
        self.link = link
        super.init()
        link.animator.observers.append { [weak self] scene in self?.mark.scene = scene }
    }

    /// Called whenever the link changes: a pairing that starts brings the panel up by itself.
    public func refresh() {
        let pairing = link.node.pairing
        if let p = pairing, !p.done, !wasPairing {
            show()
            NSApp.requestUserAttention(.informationalRequest)
        }
        wasPairing = pairing != nil && pairing?.done != true
        guard let panel, panel.isVisible else { return }
        layout()
    }

    public func show() {
        let p = panel ?? make()
        panel = p
        layout()
        if !p.isVisible { p.center() }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.delegate = self
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        code.font = .monospacedSystemFont(ofSize: 36, weight: .semibold)
        code.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 300
        primary.bezelStyle = .push
        primary.keyEquivalent = "\r"
        primary.bezelColor = Self.accent
        primary.target = self; primary.action = #selector(primaryClicked)
        secondary.bezelStyle = .push
        secondary.keyEquivalent = "\u{1b}"
        secondary.target = self; secondary.action = #selector(secondaryClicked)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 64).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let buttons = NSStackView(views: [secondary, primary])
        buttons.spacing = 8
        let stack = NSStackView(views: [mark, title, code, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: detail)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 360),
        ])
        p.contentView = content
        return p
    }

    private enum Mode { case pairing, waitingOther, failed, paired, nobody }
    private var mode: Mode = .nobody

    private func layout() {
        let n = link.node
        code.isHidden = true
        primary.isHidden = false
        secondary.isHidden = false
        if let p = n.pairing, !p.done {
            if let failed = p.failed {
                mode = .failed
                title.stringValue = "Not paired"
                detail.stringValue = failed
                primary.title = "OK"
                secondary.isHidden = true
            } else if let c = p.code {
                code.isHidden = false
                code.stringValue = c
                title.stringValue = "Pair with \(p.peerName)?"
                if p.confirmed {
                    mode = .waitingOther
                    detail.stringValue = "Waiting for you to click Pair on \(p.peerName)…"
                    primary.isHidden = true
                } else {
                    mode = .pairing
                    detail.stringValue = "Check that \(p.peerName) shows the same number. Then click Pair here and there. Everything between the two Macs is encrypted."
                    primary.title = "Pair"
                }
                secondary.title = "Cancel"
            } else {
                mode = .waitingOther
                title.stringValue = "\(p.peerName) wants to pair"
                detail.stringValue = "…"
                primary.isHidden = true
                secondary.title = "Cancel"
            }
        } else if let peer = link.pairedCapybara {
            mode = .paired
            let s = n.statuses[peer.id]
            title.stringValue = peer.name
            switch s?.phase ?? .absent {
            case .connected:
                var bits = ["Connected"]
                if let rtt = s?.rtt { bits.append(rtt < 1 ? "<1 ms" : "\(Int(rtt.rounded())) ms") }
                let waiting = n.waiting(for: peer.id).count
                if waiting > 0 { bits.append("\(waiting) waiting to send") }
                detail.stringValue = bits.joined(separator: " · ")
            case .connecting, .landing: detail.stringValue = "Connecting…"
            case .absent:
                let waiting = n.waiting(for: peer.id).count
                detail.stringValue = "Not on this network right now" + (waiting > 0 ? " · \(waiting) waiting to send" : "")
            }
            primary.title = "Done"
            secondary.title = "Unpair"
        } else {
            mode = .nobody
            title.stringValue = "Capybara"
            detail.stringValue = "Open Capybara on your other Mac, on the same network, and choose Settings › Flamingo › Pair. The six digits appear here."
            primary.title = "OK"
            secondary.isHidden = true
        }
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func primaryClicked() {
        switch mode {
        case .pairing: link.node.confirmPairing()
        case .failed: link.node.cancelPairing(tell: false); panel?.close()
        default: panel?.close()
        }
        layout()
    }

    @objc private func secondaryClicked() {
        switch mode {
        case .pairing, .waitingOther, .failed:
            link.node.cancelPairing()
            panel?.close()
        case .paired:
            if secondary.title == "Unpair" {
                // A second click confirms.
                secondary.title = "Unpair?"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.secondary.title == "Unpair?" { self?.secondary.title = "Unpair" } }
                return
            }
            if let peer = link.pairedCapybara { link.node.unpair(peer.id) }
            layout()
        case .nobody:
            panel?.close()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        // Closing during a finished pairing just tidies it away.
        if link.node.pairing?.done == true || link.node.pairing?.failed != nil { link.node.cancelPairing(tell: false) }
    }
}

/// The link in Flamingo's main window and menu: the title-bar mark, the larger animation while
/// connecting, and Flamingo ▸ Capybara….
@MainActor
public final class CapybaraLinkUI {
    public let link: CapybaraLink
    public let panel: CapybaraPanel
    private let mark = LinkMarkView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    private var accessory: NSTitlebarAccessoryViewController?
    private var stage: LinkStage?

    public init(link: CapybaraLink) {
        self.link = link
        panel = CapybaraPanel(link: link)
        mark.onClick = { [weak self] in self?.panel.show() }
        link.animator.observers.append { [weak self] scene in
            self?.mark.scene = scene
            self?.stage?.show(scene)
        }
    }

    /// Call when the link changes (after the app's own handling).
    public func refresh() {
        panel.refresh()
        accessory?.isHidden = link.pairedCapybara == nil
        let s = link.pairedCapybara.flatMap { link.node.statuses[$0.id] }
        mark.toolTip = s.map { "\($0.peer.name): " + ($0.phase == .connected ? "connected" : $0.phase == .absent ? "not reachable" : "connecting") } ?? "Capybara"
    }

    public func attach(to window: NSWindow) {
        stage = LinkStage(window: window)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        mark.frame = NSRect(x: 4, y: 3, width: 22, height: 22)
        holder.addSubview(mark)
        let a = NSTitlebarAccessoryViewController()
        a.view = holder
        a.layoutAttribute = .trailing
        a.isHidden = link.pairedCapybara == nil
        window.addTitlebarAccessoryViewController(a)
        accessory = a
    }

    /// Adds Capybara… under Settings… in the app menu.
    public func installMenu() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let item = NSMenuItem(title: "Capybara…", action: #selector(showPanel), keyEquivalent: "")
        item.target = self
        let settings = appMenu.items.firstIndex { $0.title.hasPrefix("Settings") || $0.keyEquivalent == "," }
        appMenu.insertItem(item, at: settings.map { $0 + 1 } ?? min(2, appMenu.items.count))
    }

    @objc func showPanel() { panel.show() }
}

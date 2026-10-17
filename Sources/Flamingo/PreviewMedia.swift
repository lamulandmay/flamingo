import SwiftUI
import AVKit
import FlamingoCore

/// `AVPlayerView` for audio and video. Publishes the playhead as a `time` anchor and is
/// the shell's `AnchorNavigator` while on screen: ⌘↑/⌘↓ skip ten seconds, a chip for
/// 1:23 seeks there. Never autoplays. Plan 01 owns.
struct MediaPreview: NSViewRepresentable {
    let pane: DocumentPane
    let file: FileRef
    let url: URL
    let modified: Date?
    let jump: JumpRequest?

    init(pane: DocumentPane, file: FileRef, url: URL, modified: Date?, jump: JumpRequest?) {
        self.pane = pane; self.file = file; self.url = url; self.modified = modified; self.jump = jump
    }
    init(state: AppState, file: FileRef, url: URL, modified: Date?, jump: JumpRequest?) {
        self.init(pane: state.activePane, file: file, url: url, modified: modified, jump: jump)
    }

    func makeCoordinator() -> MediaPreviewCoordinator { MediaPreviewCoordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        context.coordinator.attach(view, pane: pane)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.show(file, url: url, modified: modified, jump: jump)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: MediaPreviewCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class MediaPreviewCoordinator: NSObject, AnchorNavigator {
    /// Seconds per ⌘↑/⌘↓.
    private static let stepSeconds = 10.0

    private weak var pane: DocumentPane?
    private weak var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var file: FileRef?
    private var url: URL?
    private var modified: Date?
    private var lastAppliedJumpID: UUID?
    private var lastSecond: Int?
    /// False until playback or a seek moves the playhead; the anchor stays nil before that.
    private var moved = false
    private var inViewUpdate = false

    var anchorKind: FileAnchor.Kind { .time }

    func attach(_ view: AVPlayerView, pane: DocumentPane) {
        self.pane = pane
        playerView = view
        pane.requestFocus = { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
    }

    func detach() {
        unload()
        if let pane, pane.navigator === self { pane.navigator = nil }
        playerView = nil
    }

    /// From `updateNSView`: swaps the player when the file (or its contents) changed,
    /// then applies a pending jump request exactly once.
    func show(_ file: FileRef, url: URL, modified: Date?, jump: JumpRequest?) {
        guard let pane, let playerView else { return }
        inViewUpdate = true
        defer { inViewUpdate = false }
        if pane.navigator !== self { pane.navigator = self }

        let firstPresentation = self.url == nil
        if url != self.url || modified != self.modified {
            unload()
            self.file = file
            self.url = url
            self.modified = modified
            playerView.controlsStyle = MediaKind.video.contains(file.ext) ? .floating : .inline
            if modified != nil {
                let player = AVPlayer(url: url)
                player.actionAtItemEnd = .pause
                self.player = player
                playerView.player = player
                let interval = CMTime(value: 1, timescale: 2)
                timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                    MainActor.assumeIsolated { self?.tick(time) }
                }
            }
        }
        if let jump, jump.file == file, jump.id != lastAppliedJumpID {
            lastAppliedJumpID = jump.id
            seek(to: firstPresentation ? (pane.anchor ?? jump.anchor) : jump.anchor)
        } else if firstPresentation, let anchor = pane.anchor { seek(to: anchor) }
    }

    private func unload() {
        if let player {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
        }
        timeObserver = nil
        player = nil
        playerView?.player = nil
        lastSecond = nil
        moved = false
    }

    // MARK: AnchorNavigator

    func step(_ delta: Int) {
        guard let player else { return }
        let now = player.currentTime()
        var target = (now.isNumeric ? now.seconds : 0) + Self.stepSeconds * Double(delta)
        if let duration = player.currentItem?.duration, duration.isNumeric {
            target = min(target, duration.seconds)
        }
        seek(toSeconds: max(0, target))
    }

    func jump(to anchor: FileAnchor) {
        // A stale navigator (selection just changed, view not yet swapped) must not move.
        guard let pane, pane.file == file else { return }
        // `AppState.jumpToAnchor` publishes the same request; mark it applied so
        // `updateNSView` does not seek a second time.
        if let request = pane.jumpRequest, request.file == file, request.anchor == anchor {
            lastAppliedJumpID = request.id
        }
        seek(to: anchor)
    }

    private func seek(to anchor: FileAnchor) {
        guard let seconds = anchor.seconds else { return }
        seek(toSeconds: max(0, seconds))
    }

    private func seek(toSeconds seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        moved = true
        lastSecond = Int(seconds.rounded(.down))
        publish(.time(seconds))
    }

    // MARK: Anchor

    /// Every 0.5s during playback and whenever the time jumps. Publishes on whole seconds.
    private func tick(_ time: CMTime) {
        guard let player, time.isNumeric else { return }
        let seconds = max(0, time.seconds)
        let second = Int(seconds.rounded(.down))
        if !moved {
            guard player.rate != 0 || second > 0 else { return }
            moved = true
        }
        guard second != lastSecond else { return }
        lastSecond = second
        publish(.time(seconds))
    }

    /// Deferred while SwiftUI is updating the view: publishing from inside an update is
    /// not allowed.
    private func publish(_ anchor: FileAnchor) {
        guard let pane, let file, pane.file == file, pane.navigator === self else { return }
        if inViewUpdate {
            Task { @MainActor [weak self] in self?.publish(anchor) }
            return
        }
        if pane.anchor != anchor { pane.anchor = anchor }
    }
}

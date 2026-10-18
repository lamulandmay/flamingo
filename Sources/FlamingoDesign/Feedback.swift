import AppKit

/// Haptics and the few sounds that aren't `Chime`, in one place, so they land with the frame
/// they belong to and never pile up. Taps are felt only with a finger on a Force Touch
/// trackpad; sounds play only while macOS's "Play user interface sound effects" is on.
///
/// Rules: a haptic marks a moment the hand crosses something (a detent, a threshold, a snap),
/// never a plain click, which the trackpad already gives. A sound marks something done that
/// is worth hearing (a thought kept, files connected, something thrown away), never navigation.
@MainActor
public enum Feedback {
    public enum Haptic {
        /// A light tick: passing a detent, snapping to a guide, hovering onto the next item of a ring.
        case detent
        /// A firmer one: crossing the point where letting go commits (a swipe, a drop).
        case threshold
        case generic

        var pattern: NSHapticFeedbackManager.FeedbackPattern {
            switch self {
            case .detent: .alignment
            case .threshold: .levelChange
            case .generic: .generic
            }
        }
    }

    private static var lastHaptic = Date.distantPast

    /// Played when the next frame is drawn, so the tick and the picture arrive together. Taps
    /// closer than 40ms are dropped: the actuator smears them into a buzz.
    public static func haptic(_ kind: Haptic) {
        let now = Date()
        guard now.timeIntervalSince(lastHaptic) > 0.04 else { return }
        lastHaptic = now
        NSHapticFeedbackManager.defaultPerformer.perform(kind.pattern, performanceTime: .drawCompleted)
    }

    /// Finder's own sounds, for the same acts in Flamingo.
    public enum Sound: String {
        /// Moving files to the Trash.
        case trash = "finder/move to trash.aif"
        /// A bookmark or pin removed.
        case poof = "dock/poof item off dock.aif"

        var url: URL {
            URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds")
                .appendingPathComponent(rawValue)
        }
    }

    private static var loaded: [Sound: NSSound] = [:]

    public static func play(_ sound: Sound) {
        guard Chime.soundsEnabled else { return }
        let s = loaded[sound] ?? NSSound(contentsOf: sound.url, byReference: true)
        guard let s else { return }
        loaded[sound] = s
        s.volume = 0.6
        s.stop()
        s.play()
    }
}

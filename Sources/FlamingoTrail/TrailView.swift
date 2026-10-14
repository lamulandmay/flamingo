import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Timeline of sessions and the files and thoughts inside them. Plan 07 owns.
public struct TrailView: View {
    public var sessions: [TrailSession]
    public var onSelect: (FileRef, FileAnchor?) -> Void
    public init(sessions: [TrailSession], onSelect: @escaping (FileRef, FileAnchor?) -> Void) {
        self.sessions = sessions; self.onSelect = onSelect
    }
    public var body: some View { Color.clear /* TODO(plan 07) */ }
}

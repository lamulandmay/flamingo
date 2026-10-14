import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The ask surface. Plan 09 owns.
public struct AskView: View {
    public var engine: AskEngine
    public var onOpen: (FileRef, FileAnchor?) -> Void
    public init(engine: AskEngine, onOpen: @escaping (FileRef, FileAnchor?) -> Void) { self.engine = engine; self.onOpen = onOpen }
    public var body: some View { Color.clear /* TODO(plan 09) */ }
}

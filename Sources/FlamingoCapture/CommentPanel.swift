import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The floating "leave a thought" field. Plan 03 owns.
public struct CommentPanel: View {
    public let target: FileRef
    public var anchor: FileAnchor?
    public var onSubmit: (Comment) -> Void
    public var onCancel: () -> Void
    @State private var text = ""

    public init(target: FileRef, anchor: FileAnchor? = nil, onSubmit: @escaping (Comment) -> Void, onCancel: @escaping () -> Void) {
        self.target = target; self.anchor = anchor; self.onSubmit = onSubmit; self.onCancel = onCancel
    }

    public var body: some View {
        // TODO(plan 03)
        TextField("", text: $text).onSubmit { onSubmit(Comment(anchor: anchor, text: text)) }
    }
}

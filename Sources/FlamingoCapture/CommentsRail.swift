import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Existing thoughts on the selected file, newest last. Clicking an anchored
/// comment asks the shell to jump there. Plan 03 owns.
public struct CommentsRail: View {
    public var comments: [Comment]
    public var onJump: (FileAnchor) -> Void
    public var onEdit: (Comment) -> Void
    public var onDelete: (Comment) -> Void
    public init(comments: [Comment], onJump: @escaping (FileAnchor) -> Void,
                onEdit: @escaping (Comment) -> Void = { _ in }, onDelete: @escaping (Comment) -> Void = { _ in }) {
        self.comments = comments; self.onJump = onJump; self.onEdit = onEdit; self.onDelete = onDelete
    }
    public var body: some View {
        // TODO(plan 03)
        List(comments) { c in Text(c.text).font(Theme.Font.body) }
    }
}

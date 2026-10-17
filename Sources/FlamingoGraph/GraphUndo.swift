import Foundation

@MainActor
final class GraphCameraChange {
    var after: GraphCamera
    init(after: GraphCamera) { self.after = after }
}

enum GraphUndoNotification {
    static let layout = Notification.Name("FlamingoGraphLayoutRestored")
    static let camera = Notification.Name("FlamingoGraphCameraRestored")
}

enum GraphUndoError: LocalizedError {
    case vaultChanged, layoutChanged

    var errorDescription: String? {
        switch self {
        case .vaultChanged: "This graph belongs to a different vault."
        case .layoutChanged: "The graph layout changed elsewhere. Reload it before undoing this change."
        }
    }
}

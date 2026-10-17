import Foundation

/// User corrections are separate from the append-only event log. Boundaries refer to the
/// first event of a session, so file renames, added events, and session titles cannot move them.
struct TrailCorrections: Codable, Equatable, Sendable {
    enum Boundary: String, Codable, Sendable { case split, merge }
    var version = 1
    var boundaries: [String: Boundary] = [:]
    var excludedSessionIDs: Set<String> = []
}

enum TrailCorrectionError: LocalizedError {
    case sessionChanged, invalidSplit, noPreviousSession, metadataChanged
    var errorDescription: String? {
        switch self {
        case .sessionChanged: "This session changed. Reload Trail and try again."
        case .invalidSplit: "Choose a stop after the beginning of the session."
        case .noPreviousSession: "There is no earlier session to merge with."
        case .metadataChanged: "Trail was changed elsewhere. Reload it before undoing this change."
        }
    }
}

struct TrailCorrectionChange: Sendable {
    var before: TrailCorrections
    var after: TrailCorrections
}

struct TrailTitleChange: Sendable {
    var sessionID: UUID
    var before: String?
    var after: String?
}

enum TrailCorrectionAction {
    case excluded(Bool)
    case splitBefore(UUID)
    case mergePrevious
    case automaticGrouping

    var undoName: String {
        switch self {
        case .excluded(let excluded): excluded ? "Exclude session from Graph" : "Include session in Graph"
        case .splitBefore: "Split session"
        case .mergePrevious: "Merge sessions"
        case .automaticGrouping: "Reset session grouping"
        }
    }
}

struct TrailCorrectionStop: Identifiable {
    var id: UUID
    var label: String
}

extension TrailSession {
    var correctionStops: [TrailCorrectionStop] {
        var files = Set<String>()
        var stops: [TrailCorrectionStop] = []
        for event in events {
            let label: String
            if let file = event.file, files.insert(file.relativePath).inserted { label = file.relativePath }
            else if event.kind == .searched, let text = event.text { label = "Search: " + text }
            else { continue }
            guard event.id != sourceEventIDs.first else { continue }
            stops.append(TrailCorrectionStop(id: event.id, label: label))
        }
        return stops
    }
}

import SwiftUI
import AppKit
import PDFKit
import AVKit
import FlamingoCore
import FlamingoIndex
import FlamingoExtract
import FlamingoDesign

struct UnifiedSearchRow: View {
    let result: UnifiedSearchResult
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                if result.isDirectory { FolderGlyph(selected: selected) }
                else { FileGlyph(ext: result.file.ext, selected: selected) }
                Text(result.file.name).font(Theme.Font.body).foregroundStyle(Theme.Color.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let anchor = result.hits.first?.anchor {
                    Text(anchor.displayLabel).font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                } else if !result.file.directory.isEmpty {
                    Text(result.file.directory).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            if let hit = result.hits.first, !hit.snippet.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    if hit.commentID != nil { Image(systemName: "text.bubble").foregroundStyle(Theme.Color.textTertiary) }
                    Text(Snippet.attributed(hit.snippet)).lineLimit(2)
                }.font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                .padding(.leading, 22)
            }
            if let coverage = result.coverage, coverage != "complete" {
                Text(Self.coverageLabel(coverage)).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.Color.selection : Color.clear)
        .clipShape(Squircle(radius: Theme.Radius.s))
        .accessibilityElement(children: .combine)
        .help(result.file.relativePath)
    }
    static func coverageLabel(_ raw: String) -> String {
        switch raw {
        case "metadataOnly": "Name only"
        case "partial": "Partial content"
        case "failed": "Content unavailable"
        case "unsupported": "Name only · unsupported content"
        default: raw
        }
    }
}

/// Search selection is deliberately independent of the editing panes: arrowing through
/// results never replaces an unsaved buffer or records a misleading work session.
struct SearchResultDetail: View {
    var state: AppState
    let vault: Vault
    let result: UnifiedSearchResult
    let query: String
    var onHitChange: (SearchHit?) -> Void = { _ in }
    let onOpen: (UnifiedSearchResult, SearchHit?, Bool) -> Void
    @State private var pickedHit: String?
    @State private var family: ArtifactFamilySnapshot?
    @State private var familyLoading = false
    @State private var familyError: String?
    @State private var comparison: ArtifactFamilyMember?
    private var hit: SearchHit? { result.hits.first { $0.id == pickedHit } ?? result.hits.first }
    private var url: URL { vault.url(for: result.file) }
    private var identity: String { vault.root.path + "/" + result.file.relativePath + "|" + String(PreviewKind.modificationDate(of: url)?.timeIntervalSince1970 ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(result.file.relativePath)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1).truncationMode(.head)
                    .onDrag { FileHandoff.itemProvider(url: url, relativePath: result.file.relativePath) }
                    .help("Drag to another app")
                Spacer(minLength: Theme.Space.s)
                if result.hits.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(result.hits) { match in
                                Button {
                                    pickedHit = match.id
                                    onHitChange(match)
                                } label: {
                                    HStack(spacing: 3) {
                                        if match.commentID != nil { Image(systemName: "text.bubble") }
                                        Text(match.anchor?.displayLabel ?? (match.commentID == nil ? "file" : "thought"))
                                    }
                                    .font(Theme.Font.monoSmall)
                                    .foregroundStyle(hit?.id == match.id ? Theme.Color.accent : Theme.Color.textTertiary)
                                }
                                .buttonStyle(.press)
                                .help(match.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""))
                            }
                        }
                    }
                    .frame(maxWidth: 260)
                    .fixedSize(horizontal: true, vertical: false)
                }
                IconButton("arrow.up.forward.app", help: "Open in Default App  ⌘↩") { onOpen(result, hit, true) }
            }
            .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s)
            .frame(height: 32)
            Hairline()
            if result.isDirectory {
                FolderGlyph(size: 44).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { onOpen(result, nil, false) }
            } else {
                SearchExactPreview(file: result.file, url: url, hit: hit, query: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if comparison != nil || !(family?.members.isEmpty ?? true) {
                    Hairline()
                    familyView.frame(maxHeight: 150).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: identity) {
            pickedHit = nil; family = nil; comparison = nil; familyError = nil
            guard !result.isDirectory else { familyLoading = false; return }
            familyLoading = true
            do {
                let snapshot = try await state.searchFamily(for: result.file)
                guard !Task.isCancelled else { return }
                family = snapshot
            } catch {
                guard !Task.isCancelled else { return }
                familyError = error.localizedDescription
            }
            familyLoading = false
        }
        .onChange(of: result.file) { pickedHit = nil }
        .onChange(of: query) { pickedHit = nil; onHitChange(nil) }
    }

    private var familyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let comparison {
                    HStack {
                        IconButton("chevron.left", help: "Back") { self.comparison = nil }
                        Text(comparison.file.name).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
                        Spacer()
                    }
                }
                if let member = comparison, let difference = member.comparison {
                    Text(difference.scope).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                    Text("\(difference.sharedSections) shared sections").font(Theme.Font.small)
                    ForEach(Array(difference.selectedOnly.prefix(4).enumerated()), id: \.offset) { _, evidence in
                        evidenceRow(evidence, label: "Text only in selected extraction")
                    }
                    ForEach(Array(difference.candidateOnly.prefix(4).enumerated()), id: \.offset) { _, evidence in
                        evidenceRow(evidence, label: "Text only in candidate extraction")
                    }
                    if difference.partial { Text("Partial extraction · differences may be incomplete").font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary) }
                } else if let family {
                    ForEach(family.members, id: \.file.relativePath) { member in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            FileGlyph(ext: member.file.ext)
                            VStack(alignment: .leading, spacing: 2) {
                                Button(member.file.name) { openMember(member) }.buttonStyle(.press(shade: nil)).font(Theme.Font.body)
                                Text(member.kind.label + " · " + member.reason).font(Theme.Font.small)
                                    .foregroundStyle(Theme.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                                Text(member.file.directory).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if member.comparison != nil {
                                Button { comparison = member } label: { Image(systemName: "rectangle.split.2x1") }.help("Compare extracted sections")
                            }
                            Button { _ = FileHandoff.copy(urls: [vault.url(for: member.file)]) } label: { Image(systemName: "doc.on.doc") }.help("Copy this file")
                        }.buttonStyle(.press)
                            .onDrag { FileHandoff.itemProvider(url: vault.url(for: member.file), relativePath: member.file.relativePath) }
                    }
                }
            }.padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func openMember(_ member: ArtifactFamilyMember) {
        let match = member.anchor.map { SearchHit(file: member.file, anchor: $0, snippet: member.reason, score: 0) }
        let candidate = UnifiedSearchResult(file: member.file, isDirectory: false, hits: match.map { [$0] } ?? [], score: 0, modified: nil, coverage: nil)
        onOpen(candidate, match, false)
    }
    private func evidenceRow(_ evidence: ArtifactFamilySectionEvidence, label: String) -> some View {
        Button {
            let match = SearchHit(file: evidence.file, anchor: evidence.anchor, snippet: evidence.excerpt, score: 0)
            let target = UnifiedSearchResult(file: evidence.file, isDirectory: false, hits: [match], score: 0, modified: nil, coverage: nil)
            onOpen(target, match, false)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label + (evidence.anchor.map { " · " + $0.label } ?? "")).font(Theme.Font.small).foregroundStyle(Theme.Color.accent)
                Text(evidence.excerpt).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.press)
    }
}

/// PDFs render the real page. Other addressable document formats show the exact extracted
/// section, explicitly labeled; a generic Quick Look thumbnail never masquerades as a slide.
struct SearchExactPreview: View {
    let file: FileRef
    let url: URL
    let hit: SearchHit?
    let query: String
    @State private var section: FlamingoExtract.Section?
    @State private var previewError: String?
    @State private var loading = false
    @State private var eligible = false
    @State private var previewPane = DocumentPane(id: .secondary)
    private var anchor: FileAnchor? { hit?.anchor }
    private var key: String { url.path + "|" + (hit?.id ?? "") + "|" + String(PreviewKind.modificationDate(of: url)?.timeIntervalSince1970 ?? 0) }
    var body: some View {
        VStack(spacing: 0) {
            if let hit, hit.commentID != nil {
                Text(Snippet.attributed(hit.snippet)).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
            }
            if let previewError {
                Text(previewError).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center).padding(Theme.Space.l).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading {
                ProgressHairline(value: nil).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if eligible, file.ext == "pdf" {
                PDFPreview(pane: previewPane, file: file, url: url, modified: PreviewKind.modificationDate(of: url), jump: previewPane.jumpRequest)
            } else if eligible, MediaKind.isMedia(file.ext) {
                MediaPreview(pane: previewPane, file: file, url: url, modified: PreviewKind.modificationDate(of: url), jump: previewPane.jumpRequest)
            } else if let section {
                SourceTextView(text: section.text, initialAnchor: localLine(in: section), file: file, query: query)
                    .id(key)
            } else if eligible {
                QuickLookPreview(url: url, modified: PreviewKind.modificationDate(of: url))
            } else { Color.clear }
        }
        .task(id: key) {
            loading = true; section = nil; previewError = nil; eligible = false
            previewPane.show(file)
            previewPane.anchor = anchor
            previewPane.jumpRequest = anchor.map { JumpRequest(file: file, anchor: $0) }
            let allowed = await Task.detached { VaultScanner.limits.allowsExtraction(of: url) && FileManager.default.isReadableFile(atPath: url.path) }.value
            guard !Task.isCancelled else { return }
            guard allowed else {
                previewError = "No preview"
                loading = false; return
            }
            eligible = true
            if file.ext == "pdf", let anchor, anchor.kind == .page {
                let count = await Task.detached { PDFDocument(url: url)?.pageCount ?? 0 }.value
                guard !Task.isCancelled else { return }
                if Int(anchor.value).map({ $0 < 1 || $0 > count }) ?? true { previewError = "The matched page is no longer available in this file." }
            } else if let anchor, !MediaKind.isMedia(file.ext), file.ext != "pdf" {
                do {
                    let extracted = try await Extract.extractInBackground(url)
                    guard !Task.isCancelled else { return }
                    section = Self.resolve(anchor: anchor, sections: extracted.sections, text: extracted.text)
                    if section == nil, anchor.kind == .cell, file.ext == "xlsx" {
                        let resolved = try await Task.detached { try XLSXExtractor().cell(anchor, in: url) }.value
                        guard !Task.isCancelled else { return }
                        section = resolved
                    }
                    if section == nil { previewError = "The matched location is no longer available in this file." }
                } catch {
                    guard !Task.isCancelled else { return }
                    previewError = error.localizedDescription
                }
            }
            guard !Task.isCancelled else { return }
            loading = false
        }
    }
    private func localLine(in section: FlamingoExtract.Section) -> FileAnchor? {
        guard let anchor, anchor.kind == .line, let line = Int(anchor.value), section.anchor.kind == .line,
              let base = Int(section.anchor.value) else { return nil }
        return FileAnchor(kind: .line, value: String(max(1, line - base + 1)))
    }
    static func resolve(anchor: FileAnchor, sections: [FlamingoExtract.Section], text: String) -> FlamingoExtract.Section? {
        if let exact = sections.first(where: { $0.anchor == anchor }) { return exact }
        if anchor.kind == .line, let target = Int(anchor.value) {
            let preceding = sections.filter { $0.anchor.kind == .line && (Int($0.anchor.value) ?? Int.max) <= target }
                .max { (Int($0.anchor.value) ?? 0) < (Int($1.anchor.value) ?? 0) }
            if let preceding, let start = Int(preceding.anchor.value), target < start + preceding.text.components(separatedBy: "\n").count { return preceding }
            if sections.isEmpty, target > 0, target <= text.components(separatedBy: "\n").count {
                return .init(anchor: .init(kind: .line, value: "1"), text: text)
            }
        }
        return nil
    }
}

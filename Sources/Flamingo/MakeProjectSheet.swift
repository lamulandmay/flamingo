import SwiftUI
import FlamingoCore
import FlamingoAgents
import FlamingoDesign

/// Plan 18's offer: the folder, who works in it, the structure it will have (the same in every
/// project, each item marked new `+`, merged `≈` or changed `~`), what moves, and two answers.
/// Return makes the project; No means don't offer it again; Esc closes and leaves the dot.
struct MakeProjectSheet: View {
    @ObservedObject var model: AgentProjectsModel
    let sheet: AgentProjectsModel.Sheet

    private var conversion: ProjectConversion { sheet.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(Theme.Space.l)
            Hairline()
            // Scrolls only when there's more than fits: a short list sits snug on the buttons.
            if structureRows.count + moves.count > 22 {
                ScrollView { changes }.frame(height: 420)
            } else {
                changes
            }
            footer
        }
        .frame(width: 520)
        .background(Theme.Color.bg)
        .tint(Theme.Color.accent)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            structure
            if !moves.isEmpty { moveList }
        }
        .padding([.horizontal, .top], Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sheet.name).font(Theme.Font.title).foregroundStyle(Theme.Color.text)
            Text((sheet.root.path as NSString).abbreviatingWithTildeInPath)
                .font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1).truncationMode(.head).textSelection(.enabled)
            if !who.isEmpty {
                Text(who).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).padding(.top, Theme.Space.xs)
            }
        }
    }

    /// "Claude Code · Column sort menu", one line per harness.
    private var who: String {
        sheet.activity.map { item in
            ([item.harness.name] + [item.title].compactMap { $0 } + (item.isLive ? [] : ["earlier"])).joined(separator: " · ")
        }
        .joined(separator: "\n")
    }

    // MARK: The structure

    private enum Mark: String { case new = "+", merged = "≈", changed = "~", kept = " " }

    private var structureRows: [(String, Mark)] {
        var created = Set<String>(), merged = Set<String>(), changed = Set<String>()
        for step in conversion.steps {
            switch step {
            case .gitInit: created.insert(".git")
            case .createFolder(let p): created.insert(p + "/")
            case .createFile(let p, _): created.insert(p)
            case .writeAgents:
                if FileManager.default.fileExists(atPath: sheet.root.appendingPathComponent(ProjectStructure.agents).path) {
                    merged.insert(ProjectStructure.agents)
                } else { created.insert(ProjectStructure.agents) }
            case .resetClaude: merged.insert(ProjectStructure.claude)
            case .addGitignoreBlock: changed.insert(ProjectStructure.gitignore)
            case .move, .rewriteLinks: break
            }
        }
        let items = [ProjectStructure.agents, ProjectStructure.claude, ProjectStructure.readme, ProjectStructure.handover,
                     ProjectStructure.gitignore] + ProjectStructure.folders.map { $0 + "/" } + [".git"]
        return items.map { item in
            (item, created.contains(item) ? .new : merged.contains(item) ? .merged : changed.contains(item) ? .changed : .kept)
        }
    }

    private var structure: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(structureRows, id: \.0) { item, mark in
                HStack(spacing: Theme.Space.s) {
                    Text(mark.rawValue).frame(width: 10)
                    Text(item)
                }
                .font(Theme.Font.mono)
                .foregroundStyle(mark == .kept ? Theme.Color.textTertiary : Theme.Color.text)
                .help(help(for: item, mark))
            }
        }
    }

    private func help(for item: String, _ mark: Mark) -> String {
        switch (item, mark) {
        case (ProjectStructure.claude, .merged): "Its text moves into AGENTS.md under Rules; it becomes @AGENTS.md"
        case (ProjectStructure.agents, .merged): "Kept word for word under Rules"
        case (ProjectStructure.gitignore, .changed): "Adds scratch/ and .flamingo/; your lines stay"
        case (".git", .new): "git init; nothing is committed"
        default: ""
        }
    }

    // MARK: Moves

    private var moves: [(String, String)] {
        conversion.steps.compactMap { if case .move(let a, let b) = $0 { (a, b) } else { nil } }
    }

    private var moveList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(moves, id: \.0) { from, to in
                HStack(spacing: Theme.Space.s) {
                    Text(from).foregroundStyle(Theme.Color.textSecondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.Color.textTertiary)
                    Text(to).foregroundStyle(Theme.Color.text)
                }
                .font(Theme.Font.monoSmall)
                .lineLimit(1).truncationMode(.middle)
            }
            let links = conversion.steps.filter { if case .rewriteLinks = $0 { true } else { false } }.count
            if links > 0 || !conversion.mentions.isEmpty {
                Text(linkLine(links))
                    .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .padding(.top, Theme.Space.xs)
                    .help(mentionHelp)
            }
        }
    }

    private func linkLine(_ links: Int) -> String {
        var parts: [String] = []
        if links > 0 { parts.append("Links updated in \(links) \(links == 1 ? "file" : "files")") }
        let files = Set(conversion.mentions.map(\.file)).count
        if files > 0 {
            parts.append("\(conversion.mentions.count) plain \(conversion.mentions.count == 1 ? "mention" : "mentions") in \(files) \(files == 1 ? "file" : "files") stay as written")
        }
        return parts.joined(separator: " · ")
    }

    private var mentionHelp: String {
        conversion.mentions.prefix(20).map { "\($0.file):\($0.line)  \($0.name)" }.joined(separator: "\n")
            + (conversion.mentions.count > 20 ? "\n…" : "")
    }

    // MARK: Answers

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            let problems = conversion.blocked.map(\.description) + [sheet.error].compactMap { $0 }
            if !problems.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(problems, id: \.self) { Text($0) }
                }
                .font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
                .padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.m)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer()
                Button("No") { model.decline(sheet.root) }
                    .help("Don't offer this folder again. Make Project… stays in its menu.")
                Button("Make Project") { model.make(sheet.root) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!conversion.blocked.isEmpty)
            }
            .padding(Theme.Space.l)
        }
        .onExitCommand { model.sheet = nil }
    }
}

/// Hosts the sheet where `RootView` can show it, observing only the agents model.
struct MakeProjectHost: View {
    @ObservedObject var model: AgentProjectsModel

    var body: some View {
        Color.clear
            .sheet(item: $model.sheet) { sheet in MakeProjectSheet(model: model, sheet: sheet) }
    }
}

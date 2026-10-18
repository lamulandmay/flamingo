import SwiftUI
import FlamingoConnectors
import FlamingoDesign

// MARK: Connectors

/// Feeds and calendars Flamingo reads, for the whole app. A new one is a link (or Apple Calendar)
/// and a description; Draft turns that into a card to edit, Save keeps the full link in the
/// Keychain and refreshes.
struct ConnectorSettings: View {
    private var model: ConnectorsModel { .shared }
    @State private var adapter: ConnectorAdapter = .ical
    @State private var link = ""
    @State private var described = ""
    @State private var draft: ConnectorDraft?
    @State private var drafting = false
    @State private var error: String?
    @State private var deleting: PurposeCard?

    var body: some View {
        Form {
            if !model.rows.isEmpty {
                LabeledContent("Connectors:") {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(model.rows) { row in
                            ConnectorRowView(row: row, refreshing: model.refreshing.contains(row.id),
                                             onToggle: { model.setEnabled(row.id, $0) },
                                             onRefresh: { model.refresh(row.card) },
                                             onDelete: { deleting = row.card })
                        }
                    }
                }
                Divider().padding(.vertical, Theme.Space.s)
            }

            Picker("Source:", selection: $adapter) {
                Image(systemName: "link").help("Feed link").tag(ConnectorAdapter.ical)
                Image(systemName: "calendar").help(ConnectorAdapter.eventkit.title).tag(ConnectorAdapter.eventkit)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if adapter == .ical {
                LabeledContent("Link:") {
                    TextField("Link", text: $link, prompt: Text("webcal://…"))
                        .labelsHidden()
                        .font(Theme.Font.mono)
                        .frame(width: 320)
                }
            }
            LabeledContent("Description:") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    TextEditor(text: $described)
                        .font(Theme.Font.body)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.xs)
                        .frame(width: 320, height: 64)
                        .background(Squircle(radius: Theme.Radius.m).fill(Theme.Color.fill))
                    HStack(spacing: Theme.Space.s) {
                        Button("Draft", action: draftCard).disabled(!canDraft)
                        if drafting { ProgressView().controlSize(.small) }
                    }
                    if let error { footnote(error) }
                    footnote("Claude sees the description, the link's host and the feed's shape. Items stay on this Mac.")
                }
            }

            if let binding = Binding($draft) {
                Divider().padding(.vertical, Theme.Space.s)
                DraftFields(draft: binding)
                LabeledContent("") {
                    HStack(spacing: Theme.Space.s) {
                        Button("Save", action: save).disabled(binding.wrappedValue.card.name.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { draft = nil }
                    }
                }
            }
        }
        .formStyle(.columns)
        .task { await model.reload() }
        .onChange(of: adapter) { draft = nil; error = nil }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { card in
            Button("Delete", role: .destructive) {
                do { try model.delete(card.id) } catch { self.error = error.localizedDescription }
            }
        }
    }

    private var canDraft: Bool {
        !drafting && !described.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (adapter != .ical || !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func draftCard() {
        let adapter = adapter, link = link, described = described
        drafting = true
        error = nil
        Task {
            do { draft = try await ConnectorDrafting.draft(adapter: adapter, pasted: link, description: described) }
            catch { self.error = error.localizedDescription }
            drafting = false
        }
    }

    private func save() {
        guard let draft else { return }
        do {
            try model.add(draft)
            self.draft = nil
            link = ""; described = ""; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Name, role, what to keep and for how long, how often to look.
private struct DraftFields: View {
    @Binding var draft: ConnectorDraft

    var body: some View {
        LabeledContent("Name:") {
            TextField("Name", text: $draft.card.name).labelsHidden().frame(width: 220)
        }
        Picker("Role:", selection: $draft.card.role) {
            ForEach(ConnectorRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .fixedSize()
        if !draft.card.purpose.isEmpty {
            LabeledContent("") { footnote(draft.card.purpose) }
        }
        LabeledContent("Include:") {
            TextField("Include", text: $draft.include, prompt: Text("exam, essay")).labelsHidden().frame(width: 320)
        }
        LabeledContent("Exclude:") {
            TextField("Exclude", text: $draft.exclude, prompt: Text("cancelled")).labelsHidden().frame(width: 320)
        }
        LabeledContent("Days:") {
            HStack(spacing: Theme.Space.l) {
                Stepper("\(draft.card.window.daysBack) back", value: $draft.card.window.daysBack, in: 0...30)
                Stepper("\(draft.card.window.daysAhead) ahead", value: $draft.card.window.daysAhead, in: 1...366)
            }
            .font(Theme.Font.body).monospacedDigit()
        }
        LabeledContent("Refresh:") {
            Stepper("\(draft.card.refreshMinutes) min", value: $draft.card.refreshMinutes, in: 5...1440, step: 5)
                .font(Theme.Font.body).monospacedDigit()
        }
    }
}

/// On/off, name, role and the last refresh or its error, refresh now, delete.
private struct ConnectorRowView: View {
    let row: ConnectorRow
    let refreshing: Bool
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Toggle(row.card.name, isOn: Binding(get: { row.card.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.card.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(row.card.enabled ? Theme.Color.text : Theme.Color.textTertiary)
                    .lineLimit(1)
                HStack(spacing: Theme.Space.xs) {
                    if row.state.lastError != nil {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Color.textSecondary)
                    }
                    Text(status).foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                }
                .font(Theme.Font.small)
            }
            Spacer(minLength: Theme.Space.s)
            if refreshing { ProgressView().controlSize(.mini) }
            IconButton("arrow.clockwise", help: "Refresh Now", action: onRefresh)
                .disabled(refreshing || !row.card.enabled)
            IconButton("trash", help: "Delete", action: onDelete)
        }
        .frame(width: 380)
    }

    private var status: String {
        let role = row.card.role.rawValue.capitalized
        if let error = row.state.lastError { return role + " · " + error.message }
        guard let at = row.state.refreshedAt else { return role }
        return role + " · " + at.formatted(.relative(presentation: .named))
    }
}

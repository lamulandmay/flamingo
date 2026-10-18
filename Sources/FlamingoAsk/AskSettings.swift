import AppKit
import SwiftUI
import FlamingoDesign

/// One `GET /v1/models` with the key: free, and tells a mistyped key from a working one before
/// it is stored.
enum KeyCheck {
    enum Outcome: Equatable { case valid, rejected, unchecked }

    static func run(_ key: String, session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unchecked }
        switch status {
        case 200: return .valid
        case 401: return .rejected
        default: return .unchecked   // offline, overloaded, a key scoped away from /v1/models
        }
    }
}

/// The Chat pane of Flamingo ▸ Settings: who answers, the Anthropic key, the Claude model, the
/// local models. Plan 09 owns; the shell hosts it. Thoughts never reach Claude whatever is set
/// here (`ThoughtBlindSource`), so the pane says so once.
public struct AskSettingsPane: View {
    @State private var provider = AskProvider.preferred
    @State private var model = AskEngine.preferredModel
    @State private var keySource = KeySource.current
    @State private var keyDraft = ""
    @State private var replacing = false
    @State private var checking = false
    @State private var note: String?
    @State private var modelDirectory = LlamaServer.shared.modelDirectory.path
    @State private var ollamaModel = UserDefaults.standard.string(forKey: "FlamingoOllamaModel") ?? ""

    public init() {}

    /// Claude models chat can use. The request shape (adaptive thinking, effort `low`, the
    /// search tool) works on each.
    static let models: [(id: String, name: String)] = [
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
        ("claude-fable-5-1", "Fable 5.1"),
    ]

    enum KeySource: Equatable {
        case none, keychain, environment
        static var current: KeySource {
            KeyStore.fromEnvironment ? .environment : KeyStore.stored() != nil ? .keychain : .none
        }
    }

    public var body: some View {
        Form {
            Picker("Answer with:", selection: $provider) {
                Text("Automatic").tag(AskProvider.auto)
                Text("Claude").tag(AskProvider.claude)
                Text("Local Model").tag(AskProvider.llama)
                Text("Ollama").tag(AskProvider.ollama)
            }
            .fixedSize()
            footnote(providerNote)

            Divider().padding(.vertical, Theme.Space.s)

            LabeledContent("Anthropic API key:") { keyRow }
            if let note { footnote(note) }
            Picker("Claude model:", selection: $model) {
                ForEach(Self.models, id: \.id) { Text($0.name).tag($0.id) }
                if !Self.models.contains(where: { $0.id == model }) { Text(model).tag(model) }
            }
            .fixedSize()

            Divider().padding(.vertical, Theme.Space.s)

            LabeledContent("Local model folder:") {
                HStack(spacing: Theme.Space.s) {
                    Text((modelDirectory as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1).truncationMode(.head)
                        .help(modelDirectory)
                    Button("Choose…", action: chooseModelFolder)
                }
            }
            LabeledContent("Ollama model:") {
                TextField("Ollama model", text: $ollamaModel, prompt: Text("gemma3:4b"))
                    .labelsHidden()
                    .font(Theme.Font.mono)
                    .frame(width: 200)
            }

            Divider().padding(.vertical, Theme.Space.s)

            footnote("Thoughts stay on this Mac with every setting.")
        }
        .formStyle(.columns)
        .onChange(of: provider) { if AskProvider.preferred != provider { AskProvider.preferred = provider } }
        .onChange(of: model) { if AskEngine.preferredModel != model { AskEngine.preferredModel = model } }
        .onReceive(NotificationCenter.default.publisher(for: AskProvider.didChange)) { _ in provider = AskProvider.preferred }
        .onReceive(NotificationCenter.default.publisher(for: AskEngine.settingsDidChange)) { _ in keySource = .current }
        .onChange(of: ollamaModel) {
            let name = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(name.isEmpty ? nil : name, forKey: "FlamingoOllamaModel")
        }
    }

    // MARK: Key

    @ViewBuilder private var keyRow: some View {
        switch keySource {
        case .environment:
            Text("Set by ANTHROPIC_API_KEY").foregroundStyle(Theme.Color.textSecondary)
        case .keychain where !replacing:
            HStack(spacing: Theme.Space.s) {
                Text("Saved in Keychain").foregroundStyle(Theme.Color.textSecondary)
                Button("Change…") { replacing = true; note = nil }
                Button("Remove", action: removeKey)
            }
        default:
            HStack(spacing: Theme.Space.s) {
                SecureField("Anthropic API key", text: $keyDraft)
                    .labelsHidden()
                    .font(Theme.Font.mono)
                    .frame(width: 220)
                    .onSubmit(saveKey)
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                Button("Save", action: saveKey)
                    .disabled(checking || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if replacing { Button("Cancel") { replacing = false; keyDraft = ""; note = nil } }
            }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true; note = nil
        Task { @MainActor in
            let outcome = await KeyCheck.run(key)
            checking = false
            guard outcome != .rejected else { note = "Anthropic rejected this key"; return }
            do {
                try AskEngine.setKey(key)
                keyDraft = ""; replacing = false
                keySource = .current
                note = outcome == .valid ? "Connected" : "Saved; Anthropic couldn't be reached to check it"
                NotificationCenter.default.post(name: AskEngine.settingsDidChange, object: nil)
            } catch {
                note = (error as? AskError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func removeKey() {
        do { try AskEngine.removeKey(); keySource = .current; note = nil }
        catch { note = (error as? AskError)?.errorDescription ?? error.localizedDescription }
    }

    // MARK: Local

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: modelDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "FlamingoLlamaModelDir")
        LlamaServer.shared.stop()
        modelDirectory = LlamaServer.shared.modelDirectory.path
        NotificationCenter.default.post(name: AskEngine.settingsDidChange, object: nil)
    }

    // MARK: Notes

    /// What the chosen provider does with a question, in one line.
    private var providerNote: String {
        switch provider {
        case .auto:
            return keySource == .none ? "Answers on this Mac. With a key, Claude answers while you're online."
                : "Claude answers while you're online, this Mac when you're not."
        case .claude:
            if keySource == .none, ClaudeCodeClient.executable != nil { return "Without a key, Claude Code's sign-in answers." }
            return keySource == .none ? "Needs an API key." : "Passages from your files go to Claude."
        case .llama: return "Answers on this Mac."
        case .ollama: return "Answers on this Mac through Ollama."
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

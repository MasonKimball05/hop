import AppKit
import HopCore
import Translation

// Snippets and translation.
extension LauncherModel {
    // MARK: Snippets

    func snippetRows() -> [Row] {
        var out = Snippets.search(query, in: snippets).map { snippet in
            Row(id: "snip:" + snippet.id.uuidString, title: snippet.name,
                subtitle: snippet.text.replacingOccurrences(of: "\n", with: " \u{21B5} "), icon: .symbol("text.quote"),
                actionName: "Paste", action: { [unowned self] in pasteSnippet(snippet) },
                delete: { [unowned self] in deleteSnippet(snippet) })
        }
        let name = query.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            let preview = text.count > 60 ? String(text.prefix(60)) + "\u{2026}" : text
            out.append(Row(id: "snip-new", title: "Save Clipboard as \u{201C}\(name)\u{201D}", subtitle: preview,
                           icon: .symbol("plus.circle"), actionName: "Save") { [unowned self] in saveSnippet(name: name, text: text) })
        }
        if out.isEmpty {
            out.append(Row(id: "snip-help", title: "No snippets yet", subtitle: "Copy some text, type a name for it, then press Return",
                           icon: .symbol("text.quote")))
        }
        return out
    }

    func loadSnippets() {
        let loaded = ConfigFile.load(Snippets.fileName, defaults: Snippets.defaults)
        snippets = loaded.value
        if let error = loaded.error { message = error }
        refresh()
    }

    func pasteSnippet(_ snippet: Snippet) {
        hide()
        paste(snippet.expanded(clipboard: NSPasteboard.general.string(forType: .string)))
    }

    private func saveSnippet(name: String, text: String) {
        snippets.append(Snippet(name: name, text: text))
        persistSnippets("Saved \u{201C}\(name)\u{201D}")
        query = ""
    }

    private func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persistSnippets("Deleted \u{201C}\(snippet.name)\u{201D}")
    }

    private func persistSnippets(_ done: String) {
        do {
            try ConfigFile.save(snippets, to: Snippets.fileName)
            message = done
        } catch {
            message = "Couldn\u{2019}t save snippets: \(error.localizedDescription)"
        }
    }

    // MARK: Translation

    /// "de good morning" translates to German, "en guten Morgen" to English.
    static let translationTargets: [String: (code: String, name: String)] = [
        "de": ("de", "German"), "en": ("en", "English"), "es": ("es", "Spanish"), "fr": ("fr", "French"),
    ]

    func translationRows(for text: String) -> [Row] {
        guard let space = text.firstIndex(of: " "),
              let target = Self.translationTargets[text[..<space].lowercased()] else { return [] }
        let source = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return [] }

        if translation.input == source, translation.target == target.code {
            if let result = translation.result {
                return [Row(id: "translation", title: result, subtitle: "\(target.name) \u{00B7} on-device", icon: .symbol("character.bubble.fill", .systemBlue),
                            actionName: "Copy Translation") { [unowned self] in copyAndClose(result) }]
            }
            if let problem = translation.problem {
                return [Row(id: "translation", title: problem, subtitle: "Download languages in System Settings \u{25B8} General \u{25B8} Language & Region \u{25B8} Translation Languages",
                            icon: .symbol("exclamationmark.bubble"), actionName: "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }]
            }
        } else {
            scheduleTranslation(source, to: target.code)
        }
        return [Row(id: "translation", title: "Translating to \(target.name)\u{2026}", subtitle: source, icon: .symbol("character.bubble"))]
    }

    /// Translates after a short pause in typing, so each keystroke doesn't start one.
    private func scheduleTranslation(_ text: String, to target: String) {
        translation.pending?.cancel()
        translation = TranslationState(input: text, target: target)
        translation.pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let outcome = await Self.translate(text, to: target)
            guard !Task.isCancelled, translation.input == text, translation.target == target else { return }
            switch outcome {
            case .success(let result): translation.result = result
            case .failure(let problem): translation.problem = problem.message
            }
            if mode == .search { refreshKeepingSelection() }
        }
    }

    struct TranslationProblem: Error { let message: String }

    /// English and German go both ways; the source is whichever one isn't the target.
    private static func translate(_ text: String, to target: String) async -> Result<String, TranslationProblem> {
        let targetLanguage = Locale.Language(identifier: target)
        let sourceLanguage = Locale.Language(identifier: target == "en" ? "de" : "en")
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            do {
                let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
                return .success(try await session.translate(text).targetText)
            } catch {
                return .failure(TranslationProblem(message: "Translation failed: \(error.localizedDescription)"))
            }
        case .supported:
            return .failure(TranslationProblem(message: "The languages for this aren\u{2019}t downloaded yet"))
        default:
            return .failure(TranslationProblem(message: "macOS can\u{2019}t translate between these languages"))
        }
    }
}

/// The translation being shown in the main search.
struct TranslationState {
    var input = ""
    var target = ""
    var result: String?
    var problem: String?
    var pending: Task<Void, Never>?
}

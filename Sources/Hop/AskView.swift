import AppKit
import HopCore
import SwiftUI
import UniformTypeIdentifiers

struct AskView: View {
    @Bindable var model: AskModel
    @FocusState private var fieldFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 320, minHeight: 300)
        .background(.regularMaterial)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(Label("Drop to ask about it", systemImage: "paperclip").font(.system(size: 14, weight: .medium)))
                    .padding(6)
            }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusCount) { fieldFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            // Room for the close button in the transparent title bar.
            Spacer().frame(width: 52)
            Image(systemName: "sparkles").foregroundStyle(.orange)
            Text("Ask Claude").font(.system(size: 13, weight: .semibold))
            if model.isWatching {
                Label("Watching", systemImage: "eye.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
            }
            Spacer()
            Menu {
                Toggle("Take Notes", isOn: $model.isTakingNotes)
                Button("Make Study Guide", action: model.makeStudyGuide)
                    .disabled(model.messages.isEmpty || model.isRunning)
                Divider()
                Button("Open Today\u{2019}s Notes", action: model.openNotes)
            } label: {
                Image(systemName: model.isTakingNotes ? "note.text" : "note")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(model.isTakingNotes ? Color.accentColor : .secondary)
            .help(model.isTakingNotes ? "Taking notes: each answer goes in today\u{2019}s file in Hop Notes" : "Study notes")
            Toggle(isOn: $model.isTutoring) {
                Label("Tutor Mode", systemImage: model.isTutoring ? "graduationcap.fill" : "graduationcap")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(model.isTutoring ? Color.accentColor : .secondary)
            .help(model.isTutoring
                  ? "Tutor mode: Claude guides you and checks your work instead of giving answers. Click to turn off."
                  : "Tutor mode: guide and check my work instead of giving answers")
            Button("New Chat", systemImage: "square.and.pencil", action: model.newChat)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Start over (\u{2318}N)")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.messages.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty { emptyState }
                    ForEach(model.messages) { message in
                        MessageView(message: message,
                                    isStreaming: model.isRunning && message.id == model.messages.last?.id,
                                    copy: { model.copy(message, markdown: $0) },
                                    paste: { model.paste(message) },
                                    addToDaybook: { model.addToDaybook(message.id, keeping: $0) },
                                    wasAdded: model.wasAdded)
                            .id(message.id)
                    }
                    if isWaiting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.messages.last?.withScreen == true ? "Looking at your screen\u{2026}" : "Thinking\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Scrolling targets this, so the last line keeps some room above the field.
                    Color.clear.frame(height: 6).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .onChange(of: model.messages.last?.text) { scrollToEnd(proxy) }
            .onChange(of: model.messages.count) { scrollToEnd(proxy) }
            .onChange(of: model.isRunning) { scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    /// Waiting for the first words of a reply.
    private var isWaiting: Bool {
        model.isRunning && [.user, .watch].contains(model.messages.last?.role)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("end", anchor: .bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about whatever\u{2019}s on your screen.")
                .font(.system(size: 14, weight: .medium))
            Text("Each question sends a screenshot of the display under the mouse, without this window. Try \u{201C}how do I export this as a PDF?\u{201D} or \u{201C}what does this error mean?\u{201D}")
                .foregroundStyle(.secondary)
            Text("Working through several questions? Turn on watching (the eye) and Claude follows along as your screen changes, without you sending each one.")
                .foregroundStyle(.secondary)
            Text("\(Shortcuts.display(.ask)) shows and hides this window from anywhere.")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13))
        .padding(.top, 8)
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let area = model.area { areaChip(area) }
            if let file = model.attachedText { fileChip(file) }
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The area attached with Ask About Area, going with the next question.
    private func areaChip(_ area: ScreenCapture.Shot) -> some View {
        HStack(spacing: 8) {
            Image(decorative: area.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 64, maxHeight: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("\(model.areaName ?? "Area") attached; ask about it, or press Return")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Remove", systemImage: "xmark.circle.fill", action: model.removeArea)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A dropped document, going with the next question.
    private func fileChip(_ file: AskModel.AttachedText) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(file.text.count.formatted()) characters; ask about it, or press Return")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", systemImage: "xmark.circle.fill", action: model.removeArea)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.area != nil || model.attachedText != nil
    }

    /// Files from Finder, or images dragged out of a browser or Preview.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in model.attach(file: url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                Task { @MainActor in model.attach(area: image, name: "Dropped image") }
            }
            return true
        }
        return false
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Toggle(isOn: $model.includeScreen) {
                Image(systemName: model.includeScreen ? "camera.viewfinder" : "camera")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(model.includeScreen ? "Sending a screenshot with each question" : "Not sending screenshots")
            .disabled(model.isWatching)
            .padding(.bottom, 3)

            Button(model.isWatching ? "Stop Watching" : "Watch Screen", systemImage: model.isWatching ? "eye.fill" : "eye",
                   action: model.toggleWatching)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(model.isWatching ? Color.orange : .secondary)
                .help(model.isWatching
                      ? "Watching: Claude gets a new screenshot whenever your screen changes. Click to stop."
                      : "Watch: send the screen by itself whenever it changes, for working through several questions")
                .padding(.bottom, 3)

            Button(model.isListening ? "Stop and Send" : "Ask Out Loud", systemImage: model.isListening ? "mic.fill" : "mic",
                   action: model.toggleListening)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(model.isListening ? Color.red : .secondary)
                .symbolEffect(.pulse, isActive: model.isListening)
                .help(model.isListening ? "Listening; click to send (or let go of \(Shortcuts.display(.talk)))" : "Ask out loud (or hold \(Shortcuts.display(.talk)) anywhere)")
                .padding(.bottom, 3)

            TextField(model.isListening ? "Listening\u{2026}" : model.area != nil ? "Ask about this area\u{2026}" : model.messages.isEmpty ? "Ask about your screen\u{2026}" : "Follow up\u{2026}",
                      text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($fieldFocused)
                .onSubmit { model.send() }
                .onKeyPress(.escape) { model.close(); return .handled }

            if model.isRunning {
                Button("Stop", systemImage: "stop.circle.fill", action: model.stop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.system(size: 18))
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { model.send() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.system(size: 18))
                    .foregroundStyle(canSend ? Color.accentColor : .secondary)
                    .disabled(!canSend)
            }
        }
    }
}

private struct MessageView: View {
    let message: AskModel.Message
    let isStreaming: Bool
    /// true: copy as Markdown.
    let copy: (Bool) -> Void
    let paste: () -> Void
    let addToDaybook: ([Deadlines.Item]) -> Void
    let wasAdded: (Deadlines.Item) -> Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if message.withScreen {
                        Label("with screenshot", systemImage: "camera.viewfinder")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.system(size: 13))
        case .claude:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                if !isStreaming {
                    HStack(spacing: 12) {
                        Button("Copy", systemImage: "doc.on.doc") { copy(false) }
                        Button("Paste into App", systemImage: "arrow.down.doc") { paste() }
                            .help("Paste this answer as plain text where you were typing (\(Shortcuts.display(.pasteAnswer)) pastes the latest answer from anywhere)")
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
                Button("Copy") { copy(false) }
                Button("Copy as Markdown") { copy(true) }
                Button("Paste into App", action: paste)
            }
        case .deadlines:
            DeadlinesCard(message: message, add: addToDaybook, wasAdded: wasAdded)
        case .watch, .note:
            HStack(spacing: 6) {
                VStack { Divider() }
                Label(message.text, systemImage: message.role == .watch ? "eye" : message.symbol ?? "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                VStack { Divider() }
            }
        case .error:
            Label { Text(markdown).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    /// Bold, code and links render; line breaks and list numbering are kept as typed.
    private var markdown: AttributedString {
        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }
}

/// Due dates read off the screen, to untick any that are wrong before they go to Daybook.
private struct DeadlinesCard: View {
    let message: AskModel.Message
    let add: ([Deadlines.Item]) -> Void
    let wasAdded: (Deadlines.Item) -> Bool
    /// Starts with the ones already in Daybook unticked.
    @State private var skipped: Set<Int>?

    private var items: [Deadlines.Item] { message.deadlines ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.text)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Toggle(isOn: Binding(get: { !unticked.contains(index) },
                                         set: { if $0 { skipped = unticked.subtracting([index]) } else { skipped = unticked.union([index]) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 13))
                            Text(when(item) + (message.added == nil && wasAdded(item) ? " \u{00B7} already in Daybook" : ""))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(message.added != nil)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let added = message.added {
                Label("Added \(added) to Daybook", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                let chosen = items.indices.filter { !unticked.contains($0) }.map { items[$0] }
                Button("Add \(chosen.count) to Daybook") { add(chosen) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(chosen.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unticked: Set<Int> {
        skipped ?? Set(items.indices.filter { wasAdded(items[$0]) })
    }

    private func when(_ item: Deadlines.Item) -> String {
        guard let (date, hasTime) = Deadlines.date(item) else { return item.due }
        let day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return hasTime ? day + " \u{00B7} " + date.formatted(date: .omitted, time: .shortened) : day
    }
}

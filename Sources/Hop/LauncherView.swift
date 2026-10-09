import AppKit
import SwiftUI

struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: LauncherPanel.size.width, height: LauncherPanel.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { fieldFocused = true }
        .onChange(of: model.openCount) { fieldFocused = true }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            if let title = model.mode.title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($fieldFocused)
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.return) { model.performSelected(); return .handled }
                .onKeyPress(.escape) { model.escape(); return .handled }
                .onKeyPress(keys: [.delete], phases: .down) { press in
                    // ⌘⌫ removes the selected clipboard entry or snippet.
                    guard press.modifiers.contains(.command), model.selectedRow?.delete != nil else { return .ignored }
                    model.deleteSelected()
                    return .handled
                }
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, selected: index == model.selection, icon: icon(for: row))
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                model.performSelected()
                            }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) {
                if let row = model.selectedRow { proxy.scrollTo(row.id) }
            }
        }
    }

    private func icon(for row: LauncherModel.Row) -> NSImage? {
        if case .app(let url) = row.icon { return model.icon(for: url) }
        return nil
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text(model.message ?? hint)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer()
            if let action = model.selectedRow?.actionName, !action.isEmpty {
                Key(text: action, key: "\u{21A9}")
            }
            if model.selectedRow?.delete != nil {
                Key(text: "Delete", key: "\u{2318}\u{232B}")
            }
            Key(text: model.mode == .search ? "Close" : "Back", key: "esc")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var hint: String {
        switch model.mode {
        case .search: "Try \u{201C}5 km in mi\u{201D}, \u{201C}ask how do I export this\u{201D}, \u{201C}task call mom friday\u{201D} or \u{201C}repo hop\u{201D}"
        case .clipboard: "Kept in memory only, never saved to disk"
        case .snippets: "{date}, {time} and {clipboard} fill in when pasted"
        case .homebase, .homebaseApp: "Talking to homebase on the desktop"
        case .checkup: "Checked by the public site checkup"
        case .repos, .repo: "Projects in ~/Documents/GitHub"
        case .ports, .port: "TCP ports with a process listening"
        case .library: "Plays in Media Player, resuming where any Mac left off"
        case .jobs: "From Job Tracker on the desktop"
        case .daybook: "From Daybook; Return on a task checks it off"
        }
    }
}

private struct RowView: View {
    let row: LauncherModel.Row
    let selected: Bool
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let accessory = row.accessory {
                Text(accessory)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var iconView: some View {
        switch row.icon {
        case .app:
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 17))
                .foregroundStyle(color.map { Color(nsColor: $0) } ?? .secondary)
        }
    }
}

/// "Open Application ↩" style hints in the footer.
private struct Key: View {
    let text: String
    let key: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text).foregroundStyle(.secondary)
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

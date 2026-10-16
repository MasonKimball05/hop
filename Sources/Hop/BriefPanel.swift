import AppKit
import HopCore
import SwiftUI

/// Today's Daybook brief: the text version (brief.md) the morning brief task writes for
/// the iPhone, read fresh each time the window opens.
@MainActor
@Observable
final class BriefModel {
    private(set) var text: String?
    private(set) var written: Date?

    static var file: URL { Daybook.feedURL.deletingLastPathComponent().appending(path: "brief.md") }

    var isToday: Bool { written.map(Calendar.current.isDateInToday) ?? false }

    func load() {
        text = try? String(contentsOf: Self.file, encoding: .utf8)
        written = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

final class BriefPanel: NSPanel {
    private let model = BriefModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                   styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Today\u{2019}s Brief"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 340, height: 320)
        contentView = NSHostingView(rootView: BriefView(model: model))
        if !setFrameUsingName("TodaysBrief") { center() }
        setFrameAutosaveName("TodaysBrief")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    func load() { model.load() }

    func show() { makeKeyAndOrderFront(nil) }
}

private struct BriefView: View {
    let model: BriefModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer().frame(width: 52) // the close button
                Image(systemName: "sun.horizon").foregroundStyle(.orange)
                Text(written).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Open in Daybook", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(Daybook.showLink(nil)) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Divider()
            if let text = model.text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.isToday {
                            Label("This one is from \(model.written?.formatted(.dateTime.weekday(.wide).month().day()) ?? "an earlier day"); today\u{2019}s hasn\u{2019}t been made yet.",
                                  systemImage: "clock.badge.exclamationmark")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                        MarkdownView(text: text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                    .padding(18)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sun.horizon").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No brief yet").font(.system(size: 14, weight: .medium))
                    Text("Daybook\u{2019}s morning brief task writes it each morning at 7:30.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 340, minHeight: 320)
        .background(.regularMaterial)
    }

    private var written: String {
        guard let date = model.written else { return "Today\u{2019}s brief" }
        return "Written \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))"
    }
}

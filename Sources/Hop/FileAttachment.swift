import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A file dropped on the Ask window, read into what Claude can take: its text, or an
/// image of it.
enum FileAttachment {
    enum Content {
        case text(String)
        case image(CGImage)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func read(_ url: URL) throws(Failure) -> Content {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw Failure(errorDescription: "Couldn\u{2019}t open \(url.lastPathComponent) as an image.")
            }
            return .image(image)
        }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else {
                throw Failure(errorDescription: "Couldn\u{2019}t open \(url.lastPathComponent).")
            }
            // A scan has little or no text: send its first page as a picture instead.
            let text = document.string ?? ""
            if text.filter({ !$0.isWhitespace }).count >= 100 { return .text(text) }
            guard let page = document.page(at: 0) else { throw Failure(errorDescription: "\(url.lastPathComponent) has no pages.") }
            let thumbnail = page.thumbnail(of: NSSize(width: 1568, height: 1568), for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw Failure(errorDescription: "Couldn\u{2019}t read \(url.lastPathComponent).")
            }
            return .image(image)
        }
        // Plain text, code, CSV, JSON, Markdown…
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return .text(text)
        }
        // Word, RTF, HTML and OpenDocument, through AppKit's document readers. Only these:
        // the readers take any file as plain text, so a program would come out as junk.
        let documents: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive"]
        if documents.contains(url.pathExtension.lowercased()),
           let document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil), !document.string.isEmpty {
            return .text(document.string)
        }
        throw Failure(errorDescription: "Hop can\u{2019}t read \(url.lastPathComponent). Images, PDFs, text and Word files work.")
    }
}

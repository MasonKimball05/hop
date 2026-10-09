import AppKit
import HopCore
import ScreenCaptureKit

/// Screenshots for Ask Claude. Needs Screen Recording permission (Privacy &
/// Security ▸ Screen & System Audio Recording), which macOS asks for once.
@MainActor
enum ScreenCapture {
    enum Failure: LocalizedError {
        case notAllowed, noDisplay, encoding

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                """
                Hop needs Screen Recording permission to show Claude your screen. Allow Hop in System Settings \u{25B8} Privacy & Security \u{25B8} Screen & System Audio Recording.

                Already on? macOS only applies it after a restart: quit Hop from the menu bar and open it again. After a rebuild the switch can look on but belong to the old build; run `tccutil reset ScreenCapture com.masonkimball.Hop`, then allow it again when asked.
                """
            case .noDisplay: "Couldn\u{2019}t find a display to capture."
            case .encoding: "Couldn\u{2019}t encode the screenshot."
            }
        }
    }

    /// Claude scales larger images down to about this on the long edge anyway,
    /// so sending more only adds upload time.
    static let maxSide = 1568.0

    struct Shot {
        /// What Claude sees.
        let jpeg: Data
        /// A tiny grayscale copy for watch mode to tell whether the screen changed.
        let thumbnail: [UInt8]
        /// The app whose window this is, for a `frontWindow` capture.
        let appName: String?
        let image: CGImage

        /// The lines of text on screen, read on this Mac by Vision, for watch mode to
        /// tell the next question from the last one.
        func lines() async -> Set<String> {
            ScreenWatch.lines(in: await TextRecognition.lines(in: image, fast: true))
        }
    }

    enum Scope {
        /// The display under the mouse, without Hop's own windows.
        case display
        /// Just the front window of the app you're using, so changes elsewhere on the
        /// screen don't count. Falls back to the display when there's no such window.
        case frontWindow
    }

    static func capture(_ scope: Scope = .display) async throws -> Shot {
        // Try the capture rather than asking CGPreflightScreenCaptureAccess first: it
        // can say no for a while after permission is granted.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Shows the system prompt the first time; after that it's up to System Settings.
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            throw Failure.notAllowed
        }

        if scope == .frontWindow, let (window, app) = frontWindow(in: content) {
            let config = SCStreamConfiguration()
            let scale = min(1, maxSide / max(window.frame.width, window.frame.height))
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                    configuration: config)
            return try shot(image, appName: app)
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }

        // Leave out the Ask panel (and the launcher), so Claude sees what's under them.
        let me = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == me },
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        // display.width and height are in points, about right for reading text.
        let scale = min(1, maxSide / Double(max(display.width, display.height)))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try shot(image, appName: nil)
    }

    /// The frontmost app's frontmost normal window. The Ask panel never activates
    /// Hop, so the frontmost app is the one you're working in.
    private static func frontWindow(in content: SCShareableContent) -> (SCWindow, String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        // CGWindowList is ordered front to back; SCShareableContent isn't.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = list.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier && $0[kCGWindowLayer as String] as? Int == 0
        }
        guard let number = front?[kCGWindowNumber as String] as? CGWindowID,
              let window = content.windows.first(where: { $0.windowID == number }),
              window.frame.width > 50, window.frame.height > 50 else { return nil }
        return (window, app.localizedName)
    }

    /// An area picked with `ScreenRegion`, scaled down if it's bigger than Claude reads.
    static func shot(area image: CGImage) throws -> Shot {
        let scale = min(1, maxSide / Double(max(image.width, image.height)))
        guard scale < 1 else { return try shot(image, appName: nil) }
        let (width, height) = (Int(Double(image.width) * scale), Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.encoding }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw Failure.encoding }
        return try shot(scaled, appName: nil)
    }

    private static func shot(_ image: CGImage, appName: String?) throws -> Shot {
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw Failure.encoding
        }
        return Shot(jpeg: jpeg, thumbnail: thumbnail(of: image), appName: appName, image: image)
    }

    private static func thumbnail(of image: CGImage) -> [UInt8] {
        let (width, height) = (ScreenWatch.width, ScreenWatch.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

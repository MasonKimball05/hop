import AppKit

/// Lets you drag a box over the screen, with macOS's own screenshot crosshair (the
/// one ⌘⇧4 uses: Escape cancels, Space switches to picking a window).
enum ScreenRegion {
    /// The area you picked, or nil when you pressed Escape.
    static func pick() async -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appending(path: "hop-area-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        // -i: drag to choose, -x: no shutter sound, -o: no shadow around a picked window.
        // Cancelling exits without a file (and sometimes nonzero), so errors just mean nil.
        _ = try? await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", file.path])
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

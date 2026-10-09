import Foundation

/// Hop's global keyboard shortcuts, which can be changed in Settings. Stored in user
/// defaults under "shortcuts" as JSON; an action missing there uses its default, and
/// one stored as null is turned off.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case launcher, ask, talk, explain, askArea, copyText, pasteAnswer

    public var title: String {
        switch self {
        case .launcher: "Open Hop"
        case .ask: "Ask Claude"
        case .talk: "Ask out loud (hold)"
        case .explain: "Explain Selection"
        case .askArea: "Ask About Area"
        case .copyText: "Copy Text from Screen"
        case .pasteAnswer: "Paste Latest Answer"
        }
    }

    public var defaultShortcut: Shortcut {
        switch self {
        case .launcher: Shortcut(keyCode: Shortcut.space, modifiers: Shortcut.option, key: "Space")
        case .ask: Shortcut(keyCode: Shortcut.space, modifiers: Shortcut.option | Shortcut.shift, key: "Space")
        case .talk: Shortcut(keyCode: Shortcut.space, modifiers: Shortcut.control | Shortcut.option, key: "Space")
        case .explain: Shortcut(keyCode: 14, modifiers: Shortcut.control | Shortcut.option, key: "E")
        case .askArea: Shortcut(keyCode: 0, modifiers: Shortcut.control | Shortcut.option, key: "A")
        case .copyText: Shortcut(keyCode: 8, modifiers: Shortcut.control | Shortcut.option, key: "C")
        case .pasteAnswer: Shortcut(keyCode: 9, modifiers: Shortcut.control | Shortcut.option, key: "V")
        }
    }
}

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    /// A virtual key code, as Carbon and NSEvent use.
    public let keyCode: Int
    /// Carbon modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public let modifiers: Int
    /// The key as shown: "E", "Space", "F5".
    public let key: String

    public init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    // Carbon's values, so HopCore doesn't need Carbon.
    public static let command = 1 << 8, shift = 1 << 9, option = 1 << 11, control = 1 << 12
    public static let space = 49

    /// "⌃⌥E", in the order macOS menus use.
    public var display: String {
        var out = ""
        if modifiers & Self.control != 0 { out += "\u{2303}" }
        if modifiers & Self.option != 0 { out += "\u{2325}" }
        if modifiers & Self.shift != 0 { out += "\u{21E7}" }
        if modifiers & Self.command != 0 { out += "\u{2318}" }
        return out + key
    }
}

public enum Shortcuts {
    public static let defaultsKey = "shortcuts"

    /// The shortcut for each action; nil when it's turned off.
    public static func load(from defaults: UserDefaults = .standard) -> [ShortcutAction: Shortcut?] {
        let saved = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: Shortcut?].self, from: $0) } ?? [:]
        var out: [ShortcutAction: Shortcut?] = [:]
        for action in ShortcutAction.allCases {
            out[action] = saved.keys.contains(action.rawValue) ? saved[action.rawValue]! : action.defaultShortcut
        }
        return out
    }

    public static func save(_ shortcuts: [ShortcutAction: Shortcut?], to defaults: UserDefaults = .standard) {
        // Only what differs from the defaults, so changing a default later reaches everyone.
        var changed: [String: Shortcut?] = [:]
        for (action, shortcut) in shortcuts where shortcut != action.defaultShortcut {
            changed[action.rawValue] = .some(shortcut)
        }
        if changed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(changed) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// How a shortcut reads in help text: "⌃⌥E", or "no shortcut" when it's off.
    public static func display(_ action: ShortcutAction, from defaults: UserDefaults = .standard) -> String {
        (load(from: defaults)[action] ?? nil)?.display ?? "no shortcut"
    }
}

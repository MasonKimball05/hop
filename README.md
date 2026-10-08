# Hop

A small keyboard launcher for macOS, in the spirit of Raycast and Spotlight.
Press **⌥ Space**, type, press **Return**.

- **Launch apps** with fuzzy search: "vsc" finds Visual Studio Code. Apps you open
  often rise to the top.
- **Calculate and convert**: `(12+8)*1.08`, `sqrt(2)`, `5 km in mi`, `72 f to c`, `1.5 gb in mb`.
- **Dates and times**: `3pm cst in berlin`, `time in tokyo`, `days until may 15 2027`,
  `30 days from now`, `unix`, or paste a Unix timestamp.
- **Translate** on-device with Apple's Translation framework: `de good morning`, `en guten Morgen`.
- **Clipboard history**: search recent copies and paste one. Kept in memory only, and
  anything a password manager marks as secret is never recorded.
- **Snippets**: saved text with `{date}`, `{time}` and `{clipboard}` placeholders. In
  Snippets, type a name and press Return to save what's on the clipboard.
- **Repos** (`repo hop`): my projects in ~/Documents/GitHub with branch and
  uncommitted/unpushed counts. Open one in the IDE that fits it (Xcode for Swift,
  GoLand for Go, PyCharm for Python, IntelliJ for Java, VS Code otherwise), WezTerm,
  GitHub Desktop, Finder or GitHub.
- **Ports** (`port 3000`): what's listening, and quit it.
- **Quicklinks and web search**: `g`, `yt`, `gh`, `w`, `so`, `go`, `pypi`, `mdn`
  keywords, plus bookmarks found by name. Edit them in `quicklinks.json`.
- **System**: Lock Screen, Sleep, Toggle Dark Mode, Restart/Shut Down/Log Out (macOS
  confirms), and System Settings panes by name.
- **My own services**:
  - **Library** (`play arrival`) searches my desktop's media server
    ([shelf](https://github.com/MasonKimball05/shelf)) and plays in Media Player.
    It uses Media Player's library token from the Keychain; macOS asks once.
  - **Jobs** shows follow-ups coming due and Radar matches from
    [Job Tracker](https://github.com/MasonKimball05/job-tracker), and searches the board.
    **Add Job** opens its new-job form with the link from the clipboard.
  - **Homebase** starts, stops and restarts the apps on my desktop.
  - **Daybook** ([my calendar app](https://github.com/MasonKimball05/Daybook)) shows today's
    events, tasks due and countdowns; Return on a task checks it off. With nothing typed,
    the next event is at the top. Type `task call mom friday 3pm`, `event coffee thu 2pm`,
    or `log study 10-11pm` (or `log reading 90m`) to send it to Daybook. Daybook writes
    `hop.json` for hop to read and answers `daybook://` links; hop never touches Calendar
    or Reminders itself.
  - **`check example.com`** grades a site with my public checkup.

Swift 6 and AppKit/SwiftUI, no dependencies. It lives in the menu bar (the hare),
with no Dock icon.

## Build and install

```bash
make test      # unit tests for the matching, calculator, units, history and clients
make install   # builds Hop.app, copies it to ~/Applications and starts it
```

Requires macOS 26 and Xcode 26 (Swift 6.2+). Builds go to `~/Library/Caches/Hop`
rather than `.build/`: this repo sits in an iCloud-synced folder, and iCloud's
extended attributes make `codesign` refuse the bundle.

Use **Launch at Login** in the menu bar menu to start it automatically.

### Pasting from clipboard history

Pasting into another app means sending it ⌘V, which macOS only allows with
**Accessibility** permission. The first paste shows the system prompt; allow Hop in
System Settings ▸ Privacy & Security ▸ Accessibility. Until then, choosing an entry
still puts it on the clipboard to paste yourself.

The app is signed ad hoc, so each rebuild looks like a new app to macOS: after
`make install`, toggle Hop off and on again in that Accessibility list.

## How it works

| Piece | Where | Notes |
|---|---|---|
| Global shortcut | `Sources/Hop/HotKey.swift` | Carbon's `RegisterEventHotKey`: no permission needed, and the key press never reaches the frontmost app. |
| The panel | `Sources/Hop/LauncherPanel.swift` | A non-activating `NSPanel`, like Spotlight's: it takes the keyboard without making Hop the active app, so the app you were in stays in front and pastes land there. |
| Results and actions | `Sources/Hop/LauncherModel.swift` | One model for every mode (search, clipboard, homebase, site checkup). Escape clears the query, then goes back a level, then closes. |
| Matching and ranking | `Sources/HopCore/FuzzyMatcher.swift`, `Ranking.swift` | Characters in order, with bonuses for word starts, runs, prefixes and initials. Launch counts add a boost on a log scale, so a favorite rises without burying a much better match. |
| Calculator | `Sources/HopCore/Calculator.swift` | A small recursive-descent parser (`-3^2` is −9, `2^3^2` is 512). It only answers input that looks like math, so app names never show a result. |
| Units | `Sources/HopCore/UnitConversion.swift` | Foundation's `Measurement`, with exact pound and ounce definitions (Foundation's are rounded). |
| App index | `Sources/HopCore/AppIndex.swift` | Scans the standard app folders on every open, in the background. Doesn't use `.skipsHiddenFiles`, which drops `/Applications/Safari.app` (a symlink into a system cryptex on current macOS). |
| Clipboard | `Sources/Hop/ClipboardMonitor.swift` | Checks the pasteboard's change counter twice a second, the way every clipboard manager does. Skips types listed at nspasteboard.org as concealed or transient. |

The desktop services default to `arkans-pc1` (homebase on 8090, shelf on 8095,
Job Tracker on 5206). To point one elsewhere:

```bash
defaults write com.masonkimball.Hop homebaseURL http://other-host:8090
defaults write com.masonkimball.Hop shelfURL http://other-host:8095
defaults write com.masonkimball.Hop jobTrackerURL http://other-host:5206
```

Bookmarks, search keywords and snippets live in `~/Library/Application Support/Hop/`
as `quicklinks.json` and `snippets.json`.

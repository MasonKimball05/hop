# Hop

[![CI](https://github.com/MasonKimball05/hop/actions/workflows/ci.yml/badge.svg)](https://github.com/MasonKimball05/hop/actions/workflows/ci.yml)

A small keyboard launcher for macOS, in the spirit of Raycast and Spotlight.
Press **⌥ Space**, type, press **Return**.

- **Launch apps** with fuzzy search: "vsc" finds Visual Studio Code. Apps you open
  often rise to the top.
- **Ask Claude about your screen** (**⌥⇧ Space**, or `ask how do I export this` in the
  launcher): a small floating window that stays on top while you work. Each question
  goes with a screenshot of the display under the mouse (minus Hop's own windows), and
  follow-ups keep the conversation. It runs through the `claude` CLI, signed in with my
  Claude account, so there's no API key. Advice only: it has no tools, so it can't click,
  run commands or touch files.
- **Ask out loud**: hold **⌃⌥ Space**, talk, and let go to send. Speech is turned into
  text on the Mac.
- **Paste an answer** where you're typing: **Paste into App** under any answer, or
  **⌃⌥ V** for the latest one. Pasted as plain text, without Markdown symbols.
- **Explain Selection** (**⌃⌥ E**): select text in any app (a paragraph, an error, a
  line of code) and Claude explains it in the Ask Claude window. No screenshot, so it's quick.
- **Copy Text from Screen** (**⌃⌥ C**): drag a box over anything (a PDF, a slide in a
  video, an image) and its text goes to the clipboard. Read on the Mac by Vision; nothing
  is sent anywhere.
- **Ask About Area** (**⌃⌥ A**): drag a box over part of the screen (an equation, a
  diagram, one question on a busy page) and it's attached to your next Ask Claude question.
- **Error helper** (menu bar ▸ **Watch for Coding Errors**, off by default): while a
  terminal or IDE is in front, Hop reads its window on the Mac every few seconds. When
  error output appears (`error:`, a traceback, `npm ERR!`, `command not found`…) the
  hare turns orange, and **Explain Error** in its menu has Claude explain it and the
  likely fix. Only developer apps are ever looked at.
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
    or Reminders itself. **Due Dates to Daybook** has Claude read the deadlines off the
    page you're looking at (a syllabus, an assignment list, or an area picked with ⌃⌥A)
    and lists them in Ask Claude to check over; the ones you keep become Daybook tasks.
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

`make` signs with your **Apple Development** certificate if you have one (Xcode
creates it when you sign in under Settings ▸ Accounts; no paid membership needed).
macOS ties Hop's Screen Recording and Accessibility permissions to that signature,
which stays the same across rebuilds, so you grant them once. Without the
certificate it signs ad hoc, and each rebuild looks like a new app that needs them
granted again. To pick a certificate yourself: `make install SIGN="<name or SHA-1>"`.

Use **Launch at Login** in the menu bar menu to start it automatically.

### CI and releases

GitHub Actions runs `make test` and builds Hop.app on every push to `main` and every
pull request, on macOS 26 with Xcode 26 (the oldest toolchain Hop supports); the
zipped app is attached to each run for 14 days. Pushing a version tag publishes a
release with Hop.app built at that version:

```bash
git tag v1.2.0 && git push origin v1.2.0
```

Release builds are signed ad hoc and not notarized, so the first open needs
Control-click ▸ Open (the release notes say so). `make dist` builds the same zip locally.

### Ask Claude

Needs [Claude Code](https://claude.com/claude-code) installed and signed in. Hop
uses its login, so there's no API key:

```bash
brew install --cask claude-code   # or see claude.com/claude-code for other installers
claude                            # then type /login, and /exit when it's done
```

Hop looks for `claude` in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and
`~/.claude/local`, in that order. The first question asks for **Screen Recording**
permission (System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording).

Answers come back quickly because Hop starts Claude Code when the Ask window opens
and keeps it running for the conversation, so a question goes to a process that's
already up (first words in about a second). It's left running for 15 minutes after the
last question. Answers are laid out with headings, lists, code blocks (with a Copy
button) and math written in Unicode (x², √x, ∫), since the window can't typeset LaTeX.

The camera button next to the field turns screenshots off for follow-ups that don't
need one. The microphone asks out loud (or hold ⌃⌥Space from anywhere). **Drop a file**
on the window to ask about it: images and scanned PDFs go as pictures; text, code,
CSV, PDFs with text, and Word, RTF and HTML documents go as their text.

**Due Dates to Daybook** remembers what it has added, so reading the same syllabus
again leaves those unticked.

**Explain Selection** (⌃⌥E, or the command in the launcher) reads the selection with
Accessibility, the same permission pasting uses. Apps that don't share their
selection that way get a quick ⌘C instead, and your clipboard is put back afterwards
without the copy landing in clipboard history.

**Tutor mode** (the graduation cap) is for studying: Claude says which idea or method
a question needs and walks you through it a step at a time, checks your work and
points to where it went wrong, but doesn't hand over final answers. It stays on
between conversations and can be switched partway through one.

**Study notes** (the note menu): with **Take Notes** on, each question Claude answers
is added to a Markdown file for the day in `~/Documents/Hop Notes/`. **Make Study
Guide** has Claude turn the whole conversation into a short review sheet (the key idea,
steps and mistakes to watch for, by topic) and adds it to the same file. Put the notes
somewhere else with `defaults write com.masonkimball.Hop notesFolder ~/path/to/folder`.

**Watching** (the eye button) is for working through several questions in a row. Hop
looks at the front window of the app you're using every 3 seconds (so notifications or
a video elsewhere don't count, and switching apps does), and once it has settled it reads the window's text
on the Mac (Vision, nothing sent). When a line of text has been replaced by a different
one (the next question, even one worded like the last) it sends the new screenshot by
itself; typing an answer only adds to lines, so it doesn't. Claude helps with any question it hasn't covered yet and stays quiet
otherwise. It only watches while the Ask window is open: Escape pauses it, ⌘N or the
eye stops it, and it stops by itself after 20 minutes with nothing new. Each screen
change is a turn against your Claude usage. Escape hides the window and keeps the conversation; ⌘N starts a new one.

The conversation is saved in `~/Library/Application Support/Hop/Ask/`, so it survives
Hop quitting or being rebuilt, and Claude still has the earlier questions and
screenshots when you follow up. After 3 hours with nothing asked it starts over on its
own.

#### Settings

**Settings…** in the menu bar menu (or `Hop Settings` in the launcher) has Claude's
model, how long conversations are remembered, when watching stops, tutor mode, the
notes folder, the error helper, and every keyboard shortcut: click one and press new
keys. A shortcut another app already has is marked there.

The same settings from the command line (Hop reads them the next time you ask):

```bash
# Which model answers: sonnet or haiku for speed, opus for harder problems.
defaults write com.masonkimball.Hop claudeModel sonnet

# How long a conversation is remembered with nothing asked (hours, default 3).
defaults write com.masonkimball.Hop askMemoryHours -float 8

# Minutes of watching with nothing new before it stops (default 20).
defaults write com.masonkimball.Hop watchIdleMinutes -int 45

# A specific copy of the CLI, if it isn't in one of the usual places.
defaults write com.masonkimball.Hop claudePath "$(which claude)"

# See what's set, or go back to the default for one.
defaults read com.masonkimball.Hop
defaults delete com.masonkimball.Hop claudeModel
```

#### Troubleshooting

```bash
# "Claude Code isn't signed in": sign in again.
claude    # then /login

# Check the CLI works outside Hop (should print a short reply).
echo "say hi" | claude -p

# What went wrong on the last question, if the error in the window isn't enough.
cat ~/Library/Application\ Support/Hop/Ask/last-error.log

# Forget the current conversation (same as ⌘N).
rm ~/Library/Application\ Support/Hop/Ask/conversation.json

# A permission switched on but not working (after changing how Hop is signed, or
# with ad hoc builds after every rebuild): clear it, then allow it again when asked.
# Quit and reopen Hop after allowing Screen Recording.
tccutil reset ScreenCapture com.masonkimball.Hop
tccutil reset Accessibility com.masonkimball.Hop
```

If you fork Hop, change `CFBundleIdentifier` in `Resources/Info.plist` and use your
identifier in place of `com.masonkimball.Hop` above.

Personal notes and commands with your own paths and hosts can go in a
`*.local.md` file next to this one; those are gitignored.

### Pasting from clipboard history

Pasting into another app means sending it ⌘V, which macOS only allows with
**Accessibility** permission. The first paste shows the system prompt; allow Hop in
System Settings ▸ Privacy & Security ▸ Accessibility. Until then, choosing an entry
still puts it on the clipboard to paste yourself.

With an Apple Development certificate this is a one-time step. Signed ad hoc, each
rebuild looks like a new app to macOS: after `make install`, toggle Hop off and on
again in that Accessibility list.

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
| Ask Claude | `Sources/Hop/AskModel.swift`, `ClaudeProcess.swift`, `ScreenCapture.swift`, `Sources/HopCore/ClaudeCLI.swift` | ScreenCaptureKit with Hop's windows filtered out, scaled to 1568 px (what Claude reads at) and sent as JPEG. One CLI per conversation stays open with `--input-format stream-json`, taking each question as a line on its input (the image inline) and streaming the answer back with `--include-partial-messages`; a new one starts with `--resume` when tutor mode or the model changes. Auto-memory is off (`--settings`), or "remember this" makes Claude stop to write a memory file. Hop ignores SIGPIPE so a CLI that has exited can't take it down. |
| Answer layout | `Sources/HopCore/Markdown.swift`, `Sources/Hop/MarkdownView.swift` | SwiftUI's Markdown is inline only, so blocks (headings, lists, code, quotes, math) are split out first. LaTeX that slips through becomes Unicode (`\frac{x^3}{3}` → x³⁄3). |
| Shortcuts | `Sources/HopCore/Shortcuts.swift`, `Sources/Hop/SettingsView.swift`, `HotKey.swift` | Stored as only what differs from the defaults. Hop's own shortcuts are unregistered while you record one, or pressing ⌥Space would open Hop instead of reaching the recorder. Hold-to-talk uses Carbon's key-released event. |
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

# loom-desktop

A small always-on-top macOS panel — in the spirit of
[session-dock](https://github.com/togethercomputer/session-dock) — that shows
one pill per **Loom** task with a live agent pane, and opens a chat window for
any of them. It speaks the same visual language as the
[Loom web console](https://github.com/FutureMLS-Lab/Loom):

- **Working** — the agent is generating right now: the pill wears the web
  UI's rotating conic ring (`loom-ring-spin`, indigo → green, 1.8 s per lap).
- **Finished, unseen** — the agent stopped while you were looking elsewhere:
  the ring blinks (`loom-ring-blink`) and the pill background flashes, the
  flicker that says "this one wants you now". Clicking acknowledges it
  (locally and via `/api/activity/ack`) and opens the chat.
- **Idle** — pane alive, agent waiting, nothing unseen: a quiet gray pill.

Clicking a pill opens that task in the **main window** — a sidebar of
projects and tasks, and four tabs for whichever one is selected:

| Tab | ⌘ | What it is |
| --- | --- | --- |
| Chat | ⌘1 | The conversation feed (`/conversation`): user / assistant / tool / question / event rows, question cards with options and custom answers, and a composer that types into the agent's tmux pane |
| Terminal | ⌘2 | The live pane, with the task's `PLAN.md` rendered underneath — the same pairing the web console's agent tab has |
| Files | ⌘3 | The task's markdown: a file list, a source editor, and a browser-style preview. `PLAN.md` / `WIKI.md` save back through `/template` |
| Changes | ⌘4 | Diffs across the task's worktrees, plus push / merge |

Above the tabs are the flow buttons the web console has — Deep Interview,
Run `/goal`, Write result — and start / stop / resume for the agent session.
⌘P opens any task by name, ⌘N creates one.

## How it works

- `Sources/LoomDesktop/` — a SwiftUI/AppKit accessory app. A non-activating
  `NSPanel` pinned to the top of the screen polls `/api/activity` every 4 s
  (the Loom server's own watcher cadence) and turns the snapshot into pills.
  Task titles and project names refresh on a slower cycle.
- The panel has a fixed width you set by dragging its **left or right edge**;
  pills wrap onto as many rows as that width needs, and the height follows the
  rows, growing downward. The width is remembered across restarts
  (`defaults read LoomDesktop panelWidth`) and cannot be dragged narrower than
  the widest single pill. (Geometry adapted from session-dock.)
- The **loom** capsule on the left is the fleet menu: browse every registered
  project/task and open any of them (active or not), refresh, settings, quit.
  The dot shows connection state (green/yellow/red). The same menu lives in
  the menu bar next to the clock, so the panel can be hidden without losing
  the app.
- Only the visible task polls. Switching tasks stops the previous session's
  poller, so browsing forty tasks does not leave forty pollers running; the
  feed itself tail-merges by message id and bursts after a send so replies
  land quickly — the same behavior as the loom-app.
- The terminal renders `tmux capture-pane` into an `NSTextView`. Two details
  matter and are easy to undo by accident:
  - **No line spacing, no kerning.** A TUI draws frames out of `│ ─ ╭ ╯`;
    any gap between lines breaks them into dashes.
  - **Updates replace only the span that changed.** A poll usually moves a
    spinner, not 800 lines, and rewriting the whole buffer twice a second
    re-lays out the document, drops the selection, and burns CPU.
- Scrolling is hybrid, because history lives in two places: an ordinary pane's
  scrollback comes down with the capture and scrolls locally, while a
  full-screen app (Claude Code's TUI, vim, less) draws to the alternate
  screen, which has no scrollback — there the wheel is forwarded to
  `/api/tmux/scroll`.

## Requirements

- macOS 14+, Xcode toolchain (`swift build`).
- A reachable Loom API:
  - the **loom-app gateway** (`packages/loom-app/gateway/server.mjs`, default
    `http://127.0.0.1:8787`), which injects the Loom auth token itself, or
  - a **`loom web`** instance directly (e.g. `http://127.0.0.1:8765`,
    possibly through an SSH tunnel), with its `--auth-token` value entered in
    Settings.

## Install as an app

```bash
scripts/make-app.sh          # → /Applications/Loom Desktop.app
```

This builds a signed bundle, installs it to `/Applications`, registers a
login item (`~/Library/LaunchAgents/com.loom.desktop.plist`), and starts it.

- **Open**: it auto-starts at login; or double-click it in `/Applications`;
  or `launchctl kickstart gui/$(id -u)/com.loom.desktop`. (Note: `open` from
  a terminal/automation context may leave an unnotarized app suspended at
  launch on newer macOS — `launchctl kickstart` and Finder are reliable.)
- **Quit**: menu-bar loom icon → *Quit Loom Desktop* (or ⌘Q); also in the
  panel's loom menu.
- **Hide the panel** without quitting: *Hide Dock Panel* in either menu; the
  menu-bar icon stays and *Show Dock Panel* brings it back.

The app is a menu-bar utility (`LSUIElement`): no Dock icon, no ⌘⇥ entry.

## Build & run from source

```bash
swift build -c release
./.build/release/LoomDesktop
```

Configure the URL/token via the loom menu → **Settings…** (stored in
`defaults`; domain `com.loom.desktop` for the installed app, `LoomDesktop`
for the bare binary — keys `loomBaseURL` / `loomAuthToken`). Point it at
whatever serves the Loom HTTP API: the loom-app gateway (which holds the
Loom token itself, so the app only needs the gateway's own token), or a
`loom web --auth-token …` instance reachable directly or over an SSH tunnel.

### Try it without a cluster

```bash
python3 scripts/mock-loom.py 8787          # mock Loom API
./.build/debug/LoomDesktop                 # dock shows 3 pills:
                                           #   spinning / blinking / idle
```

The mock echoes chat messages: send one and the pill spins for a few seconds,
then the reply arrives and the pill blinks until you click it.

### Dev hooks

- `LOOM_DESKTOP_OPEN_CHAT="<projectId>/<slug>"` — open that task's chat on
  launch.
- `LOOM_DESKTOP_SNAPSHOT_DIR=/tmp/snaps` — render every window's content to
  PNGs ~7 s after launch (headless UI check, no screen-recording permission
  needed). Run the bundled binary, not `.build/release/LoomDesktop`:
  notifications need a real bundle, and the bare binary aborts on launch.
- `LOOM_DESKTOP_DEBUG_EVENTS=1` — log every mouse-down to
  `~/Library/Logs/LoomDesktop-events.log`, to tell "the click never reached
  the app" apart from "a control ignored it".
- `LOOM_DESKTOP_TRACE=1` — boot trace to `/tmp/loom-boot.log`, for a launch
  that produces no window at all.

## Auto-start at login

Fill in the binary path in `launchagent/com.loom.desktop.plist.template`,
copy it to `~/Library/LaunchAgents/com.loom.desktop.plist`, then
`launchctl load` it.

## Files

| File | What it is |
| --- | --- |
| `App.swift` | App bootstrap, main menu, dev hooks |
| `TaskStore.swift` | Polls `/api/activity`, builds pill models, local acks |
| `LoomAPI.swift` / `Models.swift` | Async client + Codable payloads |
| `PanelWindow.swift` / `WrappingHStack.swift` | session-dock panel geometry (drag-width, wrap, auto-height) |
| `DockView.swift` | Pills, loom fleet menu, connection/empty states |
| `LoomRing.swift` | The web console's spinning + blinking rings in SwiftUI |
| `StatusItem.swift` | Menu-bar icon: show/hide the dock, jump to a task, quit |
| `MainWindowController.swift` / `ProjectPickerView.swift` | Main window: sidebar + inline task pane |
| `TaskWindowView.swift` | The task's header, flow buttons, and tab bar |
| `ChatSession.swift` / `ChatView.swift` | The chat module (feed, question cards, composer) |
| `SessionCache.swift` | One session per task; only the visible one polls |
| `TerminalPane.swift` | The live tmux pane: capture, typing, hybrid scrolling |
| `PlanDigest.swift` | The read-only `PLAN.md` under the terminal |
| `PlanView.swift` | The Files tab: file list, source editor, preview |
| `MarkdownPreview.swift` | `marked` in a `WKWebView`, shared by Files and the digest |
| `DiffView.swift` | The Changes tab: per-file diffs, push / merge |
| `QuickOpen.swift` / `NewTaskView.swift` | ⌘P open by name, ⌘N create a task |
| `ComposeDrafts.swift` | Unsent text, kept across tab and task switches |
| `Notifier.swift` | Finish notifications + Dock badge |
| `SettingsWindow.swift` | Base URL + bearer token |
| `Resources/` | App icon and the bundled `marked.min.js` |
| `scripts/make-app.sh` | Build, sign, install to `/Applications`, register the login item |
| `scripts/mock-loom.py` | Offline mock of the Loom API for development |
| `scripts/summon.swift` | Poke a running app to bring its windows to this screen |

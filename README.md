# loom-desktop

A small always-on-top macOS panel — in the spirit of
[session-dock](https://github.com/togethercomputer/session-dock) — that shows
one pill per **Loom** task that wants attention, and opens any of them. It
speaks the same visual language as the
[Loom web console](https://github.com/FutureMLS-Lab/Loom):

**Dock Theme** in the loom menu makes the card light or dark, or has it follow
the system (`panelTheme`, default light). It works by setting the panel's
appearance rather than by swapping a palette, so everything on the card
follows — including the header's own controls, which ask for `.primary` and
`.secondary`.

Each pill is a dark chip inside a lit rim. The rim's colour is the state:

- **Working** — the agent is generating right now: the rim runs indigo through
  cyan to green, with a mote of light travelling round the inside of it.
- **Finished, unseen** — the agent stopped while you were looking elsewhere:
  the rim goes green and blinks on the same 1.6 s cadence as the sidebar, in
  step with every other finished pill. Clicking acknowledges it (locally and
  via `/api/activity/ack`) and opens the task.
- **Idle** — pane alive, agent waiting, nothing unseen. Idle tasks are left
  off the dock entirely; they are in the sidebar, the fleet menu and ⌘P.

Clicking a pill opens that task in the **main window** — a sidebar of
projects and tasks, and four tabs for whichever one is selected. Which tab you
land on is the one you used last:

| Tab | ⌘ | What it is |
| --- | --- | --- |
| Chat | ⌘1 | The conversation feed (`/conversation`): user / assistant / tool / question / event rows, question cards with options and custom answers, and a composer that types into the agent's tmux pane |
| Terminal | ⌘2 | The live pane, with the task's `PLAN.md` rendered underneath — the same pairing the web console's agent tab has |
| Files | ⌘3 | The task directory as a small editor: a folder tree (the worktree is under `work/`) and the selected file's source, opening on `PLAN.md`. `PLAN.md` / `WIKI.md` save back through `/template`; everything else is read-only |
| Changes | ⌘4 | Diffs across the task's worktrees, plus add / remove a worktree, push, merge, and push all |

Above the tabs are the flow buttons the web console has — Deep Interview,
Run `/goal`, Write result — and, under **⋯**, start / stop / resume for the
agent session and *Notify when finished*, which has the server watch the pane
for a finishing phrase whether or not the task is open.

Projects are managed from the sidebar: **+** at the bottom adds one (an
existing folder on the Loom host, a new folder, or a repo to clone), and
right-clicking a project sets its code root or removes it from Loom — removing
unregisters the folder without deleting anything on disk.

⌘P opens any task by name, ⌘N creates one, ⌘0 brings the main window back,
⌘⇧N opens the project's notes (`<project>/.RUD/NOTES.md`, the same file the
web console edits), ⌘S saves in Files and Notes, ⌘F finds in the plan preview,
and ⌘+/⌘− set the terminal's font size.

### One thing worth knowing about pane size

tmux sizes a window to the **smallest client attached to it**, and leaves it
there when that client goes away. So viewing a task once in a small window
leaves the agent on a small screen afterwards — with nothing attached to
explain why, since the culprit has already left. The terminal's toolbar shows
the current columns × rows, and its resize button re-attaches at the size of
the window you are in now.

## How it works

- `Sources/LoomDesktop/` — a SwiftUI/AppKit app with an ordinary Dock icon
  (see the activation-policy note below). A non-activating `NSPanel`, opening
  at the top of the screen and draggable anywhere from there, polls
  `/api/activity` every 4 s (the Loom server's own watcher cadence) and turns
  the snapshot into pills. Task titles and project names refresh on a slower
  cycle. With the display asleep the cadence drops to 60 s — four seconds is
  right for a dock somebody is watching and is nine hundred requests an hour
  at a screen that is switched off — and a wake refreshes at once. Slowed
  rather than stopped, so a task finishing overnight still raises its
  notification then.
- **Dock Size** in the loom menu draws the whole dock smaller or larger
  (`panelScale`, 0.85 / 1.0 / 1.2). It changes the real metrics rather than
  zooming, so the window shrinks with the pills and more of them fit a row.
- Drag any **edge or corner** to size the panel. Dragging the height also
  fixes it: the dock stays that tall and the rows scroll inside it, instead of
  growing down the screen as tasks appear. *Fit Height to Contents* in the
  loom menu hands that back. Both are remembered (`panelWidth`, `panelHeight`;
  a height of 0 means "follow the contents").
- The panel has a fixed width you set by dragging its **left or right edge**;
  pills wrap onto as many rows as that width needs, and the height follows the
  rows, growing downward. The width is remembered across restarts
  (`defaults read com.loom.desktop panelWidth`) and cannot be dragged narrower
  than the widest single pill. (Geometry adapted from session-dock.)
- The **loom** capsule on the left is the fleet menu: browse every registered
  project/task and open any of them (active or not), refresh, settings, quit.
  The dot shows connection state (green/yellow/red). The same menu lives in
  the menu bar next to the clock, so the panel can be hidden without losing
  the app.
- Only the visible task polls. Switching tasks stops the previous session's
  poller, so browsing forty tasks does not leave forty pollers running; the
  feed itself tail-merges by message id and bursts after a send so replies
  land quickly — the same behavior as the loom-app.
- The terminal is **xterm in a `WKWebView`**, attached to the pane's pty
  through `/api/tmux/stream` — the same terminal, theme and transport the web
  console uses. Swift streams the bytes and hands them to `term.write`;
  keystrokes go back through `/api/tmux/stream-input`.
  This is worth keeping rather than "simplifying" back to `capture-pane`:
  - The stream carries **colour and cursor motion**. A capture is plain text,
    so a TUI comes out grey and, worse, redraws are lost.
  - Attaching passes **cols/rows**, so tmux sizes the pane to this window. A
    capture is laid out for whatever width the pane happens to have — 299
    columns reflowed into an 88-column view is unreadable.
  - Input is a **pty write**, so keys are just their bytes. `send-keys` needs
    tmux key names, and getting one wrong types the name into the pane.

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
  panel's loom menu. It stays quit — the login item brings it back only after
  a crash, or at the next login.
- **Hide the panel** without quitting: *Hide Dock Panel* in either menu; the
  menu-bar icon stays and *Show Dock Panel* brings it back.

The app runs as an ordinary foreground application — Dock icon (badged with
the number of finished tasks you have not looked at), ⌘⇥ entry, menu bar —
alongside its menu-bar icon and floating panel. It is deliberately not an
`LSUIElement` accessory: `App.swift` forces `.regular`, because a process
that is not a registered foreground application draws its windows fine but
never receives clicks, resizes, or focus.

## Build & run from source

```bash
swift build -c release
./.build/release/LoomDesktop
```

Configure servers via the loom menu → **Settings…**. Point each at whatever
serves the Loom HTTP API: the loom-app gateway (which holds the Loom token
itself, so the app only needs the gateway's own token), or a
`loom web --auth-token …` instance reachable directly or over an SSH tunnel.

More than one machine can be configured — one Loom per box — and the loom
menu and menu-bar item grow a **Server** submenu to switch between them.
Switching drops everything belonging to the old one: pills, transcripts, and
the terminal's stream, so no part of one machine's work is left showing under
another's name.

Stored in `defaults` (domain `com.loom.desktop` for the installed app,
`LoomDesktop` for the bare binary): `loomServers` holds the list as JSON,
`loomActiveServer` the current one's id. `loomBaseURL` / `loomAuthToken` are
still written for the server in use, so an older build keeps working.

### Try it without a cluster

```bash
python3 scripts/mock-loom.py 8787          # mock Loom API
./.build/debug/LoomDesktop                 # dock shows 2 pills: spinning
                                           # and blinking. The mock's third
                                           # task is idle, so it stays in the
                                           # sidebar and off the dock.
```

The mock echoes chat messages: send one and the pill spins for a few seconds,
then the reply arrives and the pill blinks until you click it.

### Dev hooks

- `LOOM_DESKTOP_OPEN_CHAT="<projectId>/<slug>"` — open that task's chat on
  launch.
- `LOOM_DESKTOP_WINDOW=940x640` — open the main window at that content size,
  to check cramped layouts. Without it the window clamps to its default, so
  a script cannot make it small.
- `LOOM_DESKTOP_OPEN_WINDOWS=main,notes,settings` — open windows that
  otherwise need a menu click, so a snapshot can include them. `main` selects
  no task on the way in, so reviewing the UI never spends an unread flag.
- `LOOM_DESKTOP_THEME_FLIP=dark` — switch the dock's theme eight seconds in.
  Flipping a running dock is the case that breaks: layer colours are resolved
  once and kept, so a card can half-change in a way a launch-time setting
  would never show.
- `LOOM_DESKTOP_MOCK_PILLS=1` — fill the dock with a pill in each state and
  poll nothing, so the dock can be worked on and photographed without a
  reachable server and without leaving real tasks behind on someone's machine.
  `=idle` gives the same dock with nothing animating, which is how the dock's
  cost is measured: WindowServer's load swings by twenty points on its own, so
  only the difference between these two means anything.
- `LOOM_DESKTOP_SNAPSHOT_DIR=/tmp/snaps` — render every window's content to
  PNGs ~7 s after launch (headless UI check, no screen-recording permission
  needed). Run the bundled binary, not `.build/release/LoomDesktop`:
  notifications need a real bundle, and the bare binary aborts on launch.
  **Read the result with care**: web views are captured through their own
  `takeSnapshot`, which returns DOM content but not canvas pixels, so the
  terminal is a blank rectangle here however healthy it is.
- `LOOM_DESKTOP_DUMP_TERM=1` — print what each terminal is actually showing,
  which the snapshot above cannot tell you.
- `LOOM_DESKTOP_DEBUG_EVENTS=1` — log every mouse-down to
  `~/Library/Logs/LoomDesktop-events.log`, to tell "the click never reached
  the app" apart from "a control ignored it".
- `LOOM_DESKTOP_TRACE=1` — boot trace to `/tmp/loom-boot.log`, for a launch
  that produces no window at all. `LOOM_DESKTOP_TRACE_LAYOUT=1` adds the
  panel's measure/resize decisions to the same file.

To drive the app from a script, address it by its process name: System
Events knows it as `LoomDesktop`, not "Loom Desktop", and `open -a` starts a
second copy rather than raising this one.

```bash
osascript -e 'tell application "System Events" to set frontmost of process "LoomDesktop" to true'
```

Clicks can be posted with `CGEvent` at screen coordinates, which is how the
tabs and sidebar can be exercised without a person.

## Auto-start at login

`scripts/make-app.sh` writes `~/Library/LaunchAgents/com.loom.desktop.plist`
itself, pointing at the installed bundle, so installing is all it takes.
`launchagent/com.loom.desktop.plist.template` is the same thing by hand, for a
binary somewhere else.

## Files

| File | What it is |
| --- | --- |
| `App.swift` | App bootstrap, main menu, dev hooks |
| `TaskStore.swift` | Polls `/api/activity`, builds pill models, local acks |
| `LoomAPI.swift` / `Models.swift` | Async client + Codable payloads |
| `PanelWindow.swift` / `WrappingHStack.swift` | session-dock panel geometry (drag-width, wrap, auto-height) |
| `DockView.swift` | Pills, loom fleet menu, connection/empty states |
| `LoomColors.swift` | The web console's palette, shared by every view |
| `LoomRing.swift` | The web console's spinning + blinking rings, in Core Animation |
| `StatusItem.swift` | Menu-bar icon: show/hide the dock, jump to a task, quit |
| `MainWindowController.swift` / `ProjectPickerView.swift` | Main window: sidebar + inline task pane |
| `TaskWindowView.swift` | The task's header, flow buttons, and tab bar |
| `ChatSession.swift` / `ChatView.swift` | The chat module (feed, question cards, composer) |
| `SessionCache.swift` | One session per task; only the visible one polls |
| `TerminalPane.swift` | The Terminal tab: pane on top, plan below, one scrolling page |
| `TerminalWeb.swift` | xterm in a `WKWebView`, attached to the pane's pty. The page it hosts is `Resources/terminal.html` |
| `ComposerField.swift` | The compose box: ⏎ sends, ⇧⏎ newlines, IME-safe |
| `NotesView.swift` | The project scratchpad (`.RUD/NOTES.md`), ⌘⇧N |
| `PlanDigest.swift` | The read-only `PLAN.md` under the terminal |
| `PlanView.swift` | The Files tab: the task's folder tree and source editor |
| `PlainTextEditor.swift` | The plain source editor, shared by Files and Notes |
| `MarkdownBlocks.swift` | Agent turns as blocks: tables, lists, code |
| `MarkdownPreview.swift` | `marked` in a `WKWebView`, shared by the digest and notes. The page it hosts is `Resources/markdown-preview.html` |
| `LoomResource.swift` | Finds a bundled asset, whether the app is installed or run from a checkout |
| `DiffView.swift` | The Changes tab: per-file diffs, and the task's worktrees |
| `QuickOpen.swift` / `NewTaskView.swift` | ⌘P open by name, ⌘N create a task |
| `AddProjectView.swift` | Registering a project: an existing folder, a new one, or a clone |
| `ComposeDrafts.swift` | Unsent text, kept across tab and task switches |
| `Notifier.swift` | Finish notifications + Dock badge |
| `LoomServers.swift` | The configured Looms, and which one is current |
| `SettingsWindow.swift` | Managing servers: URL, token, and switching |
| `Snapshotter.swift` | Window → PNG for the headless UI check, web views included |
| `Resources/` | App icon, the two pages the app hosts (`terminal.html`, `markdown-preview.html`), and the bundled `marked`, `xterm`, and fit addon that get spliced into them at their placeholders. Anything added here must also be copied in `make-app.sh`, or it exists for the checkout and not for the installed app. The sidebar watermark reads `loom-mark.png`, which only the installed bundle has — the bare binary runs without it |
| `scripts/make-app.sh` | Build, sign, install to `/Applications`, register the login item |
| `scripts/mock-loom.py` | Offline mock of the Loom API for development |
| `scripts/summon.swift` | Poke a running app to bring its windows to this screen |
| `scripts/preview-shot.swift` | Render the preview page to a PNG, so a typography change can be looked at rather than guessed at. Touches neither the running app nor the server |

## Licence

Noncommercial use only, under the
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)
terms in [`LICENSE`](LICENSE). Commercial use needs a separate licence from
FutureMLS-Lab.

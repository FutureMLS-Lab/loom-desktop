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

Clicking any pill opens a **chat window** — the same conversation the Loom
web console and the loom-app render (`/api/tasks/<slug>/conversation`):
user / assistant / tool / question / event rows, structured question cards
with options and custom answers, a composer that types straight into the
agent's tmux pane (`/claude/send`), an Esc button to interrupt, and a
"Start agent" action when the pane is down.

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
  project/task and open a chat for any of them (active or not), refresh,
  settings, quit. The dot shows connection state (green/yellow/red).
- Chat windows are ordinary windows (one per task, reused), polling the
  conversation feed every 2 s with tail-merges by message id, plus a staggered
  refresh burst after a send so replies land quickly — the same behavior as
  the loom-app.

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
  needed).

## Auto-start at login

Fill in the binary path in `launchagent/com.loom.desktop.plist.template`,
copy it to `~/Library/LaunchAgents/com.loom.desktop.plist`, then
`launchctl load` it.

## Files

| File | What it is |
| --- | --- |
| `App.swift` | Accessory-app bootstrap + dev hooks |
| `TaskStore.swift` | Polls `/api/activity`, builds pill models, local acks |
| `LoomAPI.swift` / `Models.swift` | Async client + Codable payloads |
| `PanelWindow.swift` / `WrappingHStack.swift` | session-dock panel geometry (drag-width, wrap, auto-height) |
| `DockView.swift` | Pills, loom fleet menu, connection/empty states |
| `LoomRing.swift` | The web console's spinning + blinking rings in SwiftUI |
| `ChatSession.swift` / `ChatView.swift` | The chat module (feed, question cards, composer) |
| `ChatWindowManager.swift` | One reusable chat window per task |
| `SettingsWindow.swift` | Base URL + bearer token |
| `scripts/mock-loom.py` | Offline mock of the Loom API for development |

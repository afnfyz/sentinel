# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Sentinel is a floating macOS dashboard that monitors AI CLI agent activity (Gemini CLI, Claude Code) in real time. It shows animated mascot cards per agent, tracks tool calls, and supports approve/deny for destructive tool use from both the mascot UI and the terminal simultaneously.

Components:
1. **`server.js`** — Express HTTP bridge (port 49152) that receives agent status updates, serves SSE to the UI, and manages session lifecycle
2. **`index.html`** — Frontend UI (SSE-based) showing animated blob mascots per agent (blue for Gemini, orange for Claude). Drag mascot to move window. Tap mascot to open activity log popover. Approve/Deny buttons appear above mascot when approval is needed. Disconnected indicator shown when server is unreachable.
3. **`Sentinel.swift`** — macOS native app that wraps `index.html` in a floating borderless `WKWebView` window with a menubar (status bar) icon
4. **`GeminiSentinel.app/`** — Proper macOS `.app` bundle (required for `open` to launch without spawning a terminal)
5. **`extension/`** — Gemini CLI extension that installs hooks globally via `gemini extensions link`
6. **`install/`** — Hook scripts for both Gemini CLI and Claude Code

## Running

Everything at once:
```bash
./start.sh
```

Or manually:
```bash
node server.js &
open GeminiSentinel.app
```

Recompile Swift after editing `Sentinel.swift`:
```bash
swiftc Sentinel.swift -o GeminiSentinel.app/Contents/MacOS/GeminiSentinel -framework Cocoa -framework WebKit
```

## Auto-launch via Hooks

The mascot auto-starts when you open Gemini CLI — no manual launch needed. This is done via the Gemini extension (`extension/`) which is installed globally with:
```bash
gemini extensions link /path/to/sentinel/extension
```

Claude Code hooks are configured in `~/.claude/settings.json` — see `install/claude-hooks.json` for the snippet to add.

## Server API

- `POST /update` — `{ id, name, status, task }` — updates agent state
- `GET /stream` — SSE endpoint, pushes `update` events on state change, sends current state immediately on connect
- `GET /state` — returns `{ sessions, history }`
- `POST /session-start` — increments active session count, used by SessionStart hook
- `POST /session-end` — decrements count; when it hits 0, server exits and mascot is killed
- `GET /wait-approval?id=<sessionId>` — long-polls until UI approves/denies (30s timeout)
- `POST /action` — `{ id, action }` — resolves a pending wait-approval (`action`: `approve` | `deny`)

Status values: `idle`, `thinking`, `working`, `needs_approval`, `success`, `error`, `warning`

Sessions auto-clear after 4 seconds on `success`, `error`, or `warning`. Non-`main` sessions are deleted; `main` resets to idle.

## Approval Flow

Only destructive tools trigger approval (write, edit, delete, etc.). Shell/bash commands are **not** gated by default. When triggered:
1. Mascot card switches to `needs_approval` with OK/NO buttons
2. Terminal prints `[tool_name] Approve? [Y/n]:`
3. Whichever responds first (mascot click or terminal keypress) wins
4. After 30s with no response, auto-approves

The hook scripts that implement this are `install/sentinel-before-tool.sh` (Gemini) and `install/sentinel-pre-tool.sh` (Claude Code). They are installed to `~/.gemini/hooks/` and `~/.claude/hooks/` respectively.

## Architecture Notes

- State is persisted to `state.json` on every update and reloaded on server start. Stale sessions from previous runs are cleaned up by the auto-clear timers.
- The Swift app uses `hidesOnDeactivate = false` and `alphaValue = 1.0` to stay fully visible regardless of which app has focus.
- The Swift app intentionally does NOT call `NSApp.activate` on launch or during normal operation — it only steals focus when a session enters `needs_approval` status. This prevents the mascot from interrupting the user's active window.
- **Drag** is implemented via `NSEvent.addLocalMonitorForEvents` for `leftMouseDown/Dragged/Up`. This intercepts events before WKWebView consumes them, enabling reliable drag-anywhere-on-the-mascot behavior. `isMovableByWindowBackground` is disabled because WKWebView blocks it.
- The mascot figure uses `pointer-events: none` on SVG/figure elements to allow drag events to pass through, with document-level tap detection for open-log clicks.
- The log popover is a single shared `position: fixed` element positioned by JS (`getBoundingClientRect`) so it never gets clipped by the window bounds.
- The `.app` bundle has `LSUIElement = true` in `Info.plist` so `open` launches it with no Dock icon and no terminal window.
- The Swift app computes the project path relative to the executable (walks three levels up from the binary inside the `.app` bundle) so it works on any machine without hardcoded paths.
- Gemini CLI only runs hooks from project-level `.gemini/settings.json` (not user-level `~/.gemini/settings.json`). The extension approach bypasses this limitation.
- `POST /session-end` returning `{ shutdown: true }` is the signal for the hook to also kill the mascot process.

## Configuring Approvals

Create `~/.sentinel/config.json` to customize which tools require approval:

```json
{
  "destructiveTools": [
    "write_file", "replace", "edit_file", "delete", "move", "create", "overwrite",
    "Write", "Edit", "NotebookEdit"
  ],
  "gateShellCommands": false
}
```

- **`destructiveTools`** — list of tool names that trigger approval. Defaults to file-mutation tools only.
- **`gateShellCommands`** — set to `true` to also gate `bash`/`run_shell_command`/`execute` for Gemini, and `Bash` for Claude. Defaults to `false`.

A template is at `install/sentinel-config-default.json`.

Tool call logs (tool name, input, approval decisions) are written to `~/.sentinel/tool.log` for Claude hooks and to `server.log` for Gemini hooks.

## Menubar Icon

The app runs as a menubar-only app (no Dock icon). Click the ♊️ icon in the menubar to access:
- **Show Mascot** — brings the floating window back if hidden
- **Hide Mascot** — hides the floating window (app stays running)
- **Restart Server** — terminates and restarts the Node server
- **Quit Sentinel** — fully exits the app and stops the server

Closing the floating window via the OS also hides it (doesn't quit the app).

## Installation

### Gemini CLI
```bash
# Install hooks
cp install/sentinel-before-tool.sh   ~/.gemini/hooks/sentinel-before-tool.sh
cp install/sentinel-session-start.sh ~/.gemini/hooks/sentinel-session-start.sh
cp install/sentinel-session-end.sh   ~/.gemini/hooks/sentinel-session-end.sh
chmod +x ~/.gemini/hooks/sentinel-*.sh

# Set SENTINEL_DIR so session-start knows where to find server.js and the .app
export SENTINEL_DIR="/path/to/sentinel"  # add to ~/.zshrc

# Link the extension (auto-launches hooks)
gemini extensions link /path/to/sentinel/extension
```

### Claude Code
```bash
cp install/sentinel-pre-tool.sh ~/.claude/hooks/sentinel-pre-tool.sh
chmod +x ~/.claude/hooks/sentinel-pre-tool.sh
```
Then merge `install/claude-hooks.json` into `~/.claude/settings.json` under the `"hooks"` key.

### Optional: Custom approval config
```bash
mkdir -p ~/.sentinel
cp install/sentinel-config-default.json ~/.sentinel/config.json
# Edit ~/.sentinel/config.json as desired
```

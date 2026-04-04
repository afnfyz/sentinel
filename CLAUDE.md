# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Sentinel is a floating macOS dashboard that monitors AI CLI agent activity (Gemini CLI, Claude Code) in real time. It shows animated mascot cards per agent, tracks tool calls, and supports approve/deny for destructive tool use from both the mascot UI and the terminal simultaneously.

Components:
1. **`server.js`** — Express HTTP bridge (port 49152) that receives agent status updates, serves SSE to the UI, and manages session lifecycle
2. **`index.html`** — Frontend dashboard (SSE-based) showing agent cards with status animations and a toggleable event log
3. **`Sentinel.swift`** — macOS native app that wraps `index.html` in a floating borderless `WKWebView` window
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

Only destructive tools trigger approval (write, edit, shell, delete, execute). When triggered:
1. Mascot card switches to `needs_approval` with OK/NO buttons
2. Terminal prints `[tool_name] Approve? [Y/n]:`
3. Whichever responds first (mascot click or terminal keypress) wins
4. After 30s with no response, auto-approves

The hook scripts that implement this are `install/sentinel-before-tool.sh` (Gemini) and `install/sentinel-pre-tool.sh` (Claude Code). They are installed to `~/.gemini/hooks/` and `~/.claude/hooks/` respectively.

## Architecture Notes

- State is persisted to `state.json` on every update and reloaded on server start. Stale sessions from previous runs are cleaned up by the auto-clear timers.
- The Swift app uses `hidesOnDeactivate = false` and `alphaValue = 1.0` to stay fully visible regardless of which app has focus.
- The `.app` bundle has `LSUIElement = true` in `Info.plist` so `open` launches it with no Dock icon and no terminal window.
- The Swift app hardcodes the HTML path to `/Users/afnan_dfx/projects/gemini-sentinel/index.html` — changing the project location requires updating `Sentinel.swift` and recompiling.
- Gemini CLI only runs hooks from project-level `.gemini/settings.json` (not user-level `~/.gemini/settings.json`). The extension approach bypasses this limitation.
- `POST /session-end` returning `{ shutdown: true }` is the signal for the hook to also kill the mascot process.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Gemini Sentinel is a floating macOS dashboard for monitoring AI agent sessions in real time. It has three components:

1. **`server.js`** — Express HTTP bridge (port 49152) that receives agent status updates and serves state to the UI
2. **`index.html`** — Frontend dashboard (polls `/state` every 800ms) showing agent cards with status animations and a toggleable event log
3. **`Sentinel.swift`** — macOS native app that wraps `index.html` in a floating `WKWebView` window
4. **`GeminiSentinel`** — Compiled arm64 binary of `Sentinel.swift`

## Running the Project

Start the bridge server:
```bash
node server.js
```

Run the macOS floating window (requires the compiled binary):
```bash
./GeminiSentinel
```

To recompile the Swift app after editing `Sentinel.swift`:
```bash
swiftc Sentinel.swift -o GeminiSentinel -framework Cocoa -framework WebKit
```

## Server API

Agents (e.g. Claude Code hooks) communicate with the server via:

- `POST /update` — `{ id, name, status, task }` — updates agent state. Status values: `idle`, `thinking`, `working`, `needs_approval`, `success`, `error`
- `GET /state` — returns `{ sessions, history }`
- `POST /action` — `{ id, action }` — resolves a pending `wait-approval` long-poll
- `GET /wait-approval?id=<sessionId>` — long-polls until user approves/denies via the UI

Sessions with `success` or `error` status auto-clear after 4 seconds (non-`main` sessions are deleted; `main` resets to `idle`).

## Architecture Notes

- The server holds all state in-memory (`sessions` object + `history` array capped at 20 entries). There is no database or persistence across restarts.
- The frontend does not use a build system — it's a single self-contained HTML file.
- The Swift app hardcodes the HTML path to `/Users/afnan_dfx/projects/gemini-sentinel/index.html` — changing the project location requires updating `Sentinel.swift` and recompiling.
- The approval flow uses long-polling: the agent calls `GET /wait-approval`, the UI posts to `POST /action`, which resolves the pending response.

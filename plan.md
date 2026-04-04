# Gemini Sentinel — Improvement Plan

---

## Critical Bugs

**XSS + prototype pollution in `POST /update`**
`sessions[sessionId] = { ...sessions[sessionId], ...req.body }` spreads the raw request body onto the session object, then the frontend renders `s.task` via `innerHTML` string interpolation. Any caller can inject arbitrary HTML or `__proto__` keys. Fix: whitelist accepted fields in the server, and switch the frontend to `textContent` / `createElement` instead of `innerHTML`.

**`/wait-approval` leaks resolver on agent disconnect**
If an agent calls `GET /wait-approval` and then crashes, `approvalResolvers[sessionId]` is never resolved and the `res` object stays open forever. Fix: add a 30s server-side timeout that responds `{ action: 'timeout' }`, and clean up on `res.on('close')`.

---

## Architecture

**Replace 800ms polling with Server-Sent Events**
The frontend polls `/state` every 800ms even when nothing has changed, then does string-comparison diffing to skip renders. Replace with a `GET /stream` SSE endpoint that pushes only on actual state changes. This cuts idle network traffic by ~75 requests/min and reduces update latency from up to 800ms to near-zero.

**Persist state across server restarts**
All sessions and history are lost if `node server.js` crashes. Write state to a local JSON file (e.g. `~/.gemini-sentinel-state.json`) on each `/update` and reload on startup. No database needed — the data is already capped at 20 history entries.

**Surface server disconnection in the UI**
The poll `catch (e) {}` silently swallows all network errors, so a crashed server looks identical to idle agents. Show a visual indicator (dimmed panel, red connection dot) when fetches fail, clearing when the connection resumes.

---

## Developer Experience

**Fix the hardcoded absolute path in `Sentinel.swift`**
Line 49: `let path = "/Users/afnan_dfx/projects/gemini-sentinel/index.html"` breaks on any other machine or directory. Resolve relative to the binary using `CommandLine.arguments[0]`'s parent directory instead.

**Add `npm start` script**
`package.json` has no `start` script. Add `"start": "node server.js"` so `npm start` works.

**Add integration examples**
`CLAUDE.md` documents the API but has no concrete usage. Add `curl` examples and a minimal shell snippet (e.g. for a Claude Code hook) so integration is copy-paste.

**Add request logging**
`server.js` logs nothing after startup. Add `morgan` middleware so request activity is visible in `server.log`, making agent misbehavior easier to debug.

**Add a launchd plist**
Include a launchd plist so the server auto-starts on login and self-heals on crash, matching the "always-on" intent of the tool.

---

## UX / UI

**Fix the history panel transition**
`display: none → display: flex` is not animatable, so the opacity transition never fires — the panel snaps in. Use `visibility: hidden` + `width: 0` in the collapsed state so the fade-in actually works.

**Add elapsed time to agent cards**
`timestamp` is stored on every session but never rendered. Show "working for 2m 34s" on the card — critical for catching runaway agents stuck in `working` state.

**Add status coloring to history log entries**
Every log entry renders identically. Add a left-border color keyed to `h.status` (using the existing CSS variables) so errors and approvals are scannable at a glance.

**Add macOS notification on approval request**
When an agent enters `needs_approval`, only the floating overlay signals it. Add a `UNUserNotificationCenter` banner from the Swift layer with the agent name and task text so approvals are impossible to miss.

**Make approval button labels more expressive**
"OK" / "NO" don't communicate what the user is approving. At minimum change to "Approve" / "Deny". Ideally surface the task text more prominently (larger font, distinct background) when approval is pending.

---

## Features

**Per-session history filter**
The 20-entry global log mixes all agents, making it noisy with multiple concurrent sessions. Add a filter toggle per agent ID in the history panel.

**Optional `detail` field in updates**
`task` is a plain string. Add an optional `detail` field (file path, command, URL) rendered as secondary text below the task, giving more information density without changing the card weight.

**Approval action confirmation**
After clicking Approve/Deny, there's no feedback that the action was received — it just disappears. If the session already auto-cleared (4s timeout), the action silently fails. Show a brief confirmation or error state on the card.

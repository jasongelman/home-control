# CLAUDE.md — Lutron Home

## Never commit an un-built merge or rebase

**After resolving any merge or rebase conflict, run a full build of every affected codebase before `git commit` or `git merge --continue`.** Do not rely on reading the diff — the failure modes below produce output that looks plausible in a diff but does not compile.

Build commands for this repo:

- **iOS** (required if `ios/**` had conflicts):
  ```
  cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
  ```
- **Server** (required if `server/**` had conflicts):
  ```
  cd server && npm run build
  ```
- **Web** (required if `web/**` had conflicts):
  ```
  cd web && npm run build
  ```

If *any* of the three is broken, the merge is not done — fix it before committing. A partial fix that makes one error go away is not enough; re-run the full build and keep going until it is green. Never assume "the rest probably compiles."

## Conflict resolution: reconcile semantically, do not "accept both"

When one side of a merge has refactored structure that the other side has added to, Git's textual conflict resolution is unsafe. You must understand what each side changed and re-express the additions in the new structure.

Procedure when you hit a non-trivial conflict:

1. Identify both parents: `git log --merge --oneline` or `git show <MERGE_HEAD>`.
2. Read each parent's version of the conflicted file with `git show <parent-sha>:<path>` — not just the `<<<<<<<` hunks, which hide surrounding context.
3. Ask: *did one side refactor the region around the conflict?* If yes, the other side's additions almost certainly need to be rewritten, not pasted. Inline view code replaced by an enum-dispatch structure (e.g., `quickActionsSection` → `DashboardItem` / `unifiedControlSection`) is the canonical example.
4. Write the resolution by hand. Then build (see above).

Red flags that you resolved a conflict wrong:
- A `switch` `case` appears inside a closure, Button label, or `if` block.
- Two `Section`s or two `VStack`s interleave at the brace level.
- A function, property, or `@State` is declared twice in the same type.
- A method call (e.g. `foo.resume()`) ends up in a sheet/toolbar/label closure instead of an event handler.
- Helper properties (e.g. `heatPumpIcon`, `heatPumpColor`) exist but nothing references them.

Any one of those means stop and re-resolve — do not try to patch around them.

## Reference: the April 2026 bad merge

Commit `247c97e` was a 15-file merge resolution committed without a build. Three files had structurally-invalid code that compiled to nothing:

- `ContentView.swift` — old `quickActionsSection` body spliced into the middle of `unifiedControlSection`'s `.forYouDevice` switch case; stray `forYouSection` with orphaned `case .staticAction` / `case .room`; duplicate `handleContextualAction`; dead `heatPumpIcon`/`heatPumpColor`.
- `SettingsView.swift` — Resideo `Section` header pasted mid-HStack inside the Chat Assistant `Section`; Resideo body trapped inside Chat Assistant's `footer` closure.
- `LutronHomeApp.swift` — `totalConnect.resume()` placed inside the `.sheet { NavigationStack { ... } }` closure instead of `.onChange(of: scenePhase)`.

The follow-up commit `cd725e9` ("Fix build error") fixed exactly one of these and stopped. That is the failure mode this rule exists to prevent: one error fixed, build not re-run, rest shipped broken.

## Repo layout

This is a three-codebase monorepo. A single feature typically touches more than one side:

- `ios/LutronHome/` — native SwiftUI app (`LutronHome` scheme, bundle id `com.jasongelman.LutronHome`). Direct LEAP connection + widget extension.
- `server/` — Node.js/TypeScript (`tsc` build). Hosts REST + WebSocket APIs and brokers integrations (HomeConnect, MyUplink, SmartHQ, MyQ, Resideo Total Connect, etc.).
- `web/` — React 19 + Vite + TypeScript client.

When you add an integration or endpoint, check whether all three sides need updates (server route, web UI, iOS UI/manager). The build-before-commit rule above applies to every codebase that a change touches.

## Keep iOS and web at feature parity

**The iOS app and the web app must expose the same user-facing features.** They are two clients of the same home — not a "primary" and a "companion." Any capability a user can reach on one must be reachable on the other, even if the UI idiom differs (SwiftUI sheet vs. MUI dialog, long-press menu vs. right-click, pill row vs. sidebar, etc.).

When you add or change a feature, the definition of done is: **the same capability works on iOS and web.** That usually means editing at least these layers in one change:

1. **Server** (`server/src/**`) — add/modify the REST route, WebSocket message, and/or integration client. This is the contract; both clients bind to it.
2. **Web** (`web/src/**`) — add the React component, wire it through `LutronContext` / `useWebSocket`, expose it in the UI (Dashboard, SettingsDialog, etc.).
3. **iOS** (`ios/LutronHome/LutronHome/**`) — add the `@Observable` manager (if a new integration), the SwiftUI view/section, and wire it into `ContentView` / `SettingsView` / `LutronHomeApp` `@State` + `.environment(...)`. Don't forget App Intents / widget exposure if the feature is one a user would reasonably want from Siri or the home screen.

Cross-layer checklist for a new integration (use the Resideo Total Connect work as the reference implementation — `server/src/totalconnect/`, `web/src/components/AlarmControl.tsx`, `ios/.../TotalConnectManager.swift`):

- [ ] Server: types, client, poller/event source, REST routes, WebSocket push + command
- [ ] Web: component, Dashboard section, Settings tab, WebSocket subscription, context state
- [ ] iOS: `@Observable` manager with Keychain/UserDefaults persistence, SwiftUI section in relevant views, `@State` + `.environment(...)` in `LutronHomeApp`, pbxproj entry for any new Swift file
- [ ] Credentials/PII stay server-side; clients get only the state they need to render

Cross-layer checklist for a UI-only change:

- [ ] Web component updated
- [ ] iOS view updated with equivalent behavior
- [ ] Both built clean (see "Never commit an un-built merge or rebase" above — same rule applies to any multi-codebase change, not only merges)

If you deliberately ship a feature on only one client (e.g. a one-off iOS widget, or a web-only debug panel), say so explicitly in the commit message with a brief reason. Silent asymmetry is the thing this rule exists to prevent — it turns into permanent drift otherwise.

## Never commit secrets

**No API key, OAuth client secret, user password, PIN, private key, or TLS cert ever lands in git.** This repo is (or may become) public. Once a secret is pushed, it is compromised permanently — rotation is the only fix, and `git filter-branch` / BFG does not undo what mirrors and scrapers already have.

### Where secrets actually live in this project

| Kind | Storage | Never in |
|------|---------|----------|
| Server-held secrets (integration client IDs/secrets, user credentials for MyQ, SmartHQ, Resideo, OAuth refresh tokens, Anthropic API key) | `server/data/config.json` (gitignored via `server/data/`) or `.env` (gitignored via `*.env` / `.env.*`) | source, tests, fixtures, logs, commit messages, docs |
| TLS cert + key for LEAP/mTLS | `ios/LutronHome/LutronHome/lutron_client.p12` (gitignored) and equivalent server-side paths outside the repo | any tracked file |
| iOS on-device secrets (user-entered credentials, bearer tokens) | Keychain via the manager's `username`/`password` setters; `UserDefaults` only for non-sensitive state | `@State` that gets logged, `print()` output, committed `.xcuserstate` |
| Web-held secrets | **none — the web client must never receive raw credentials.** It talks to `server/` which holds them. | any web source, localStorage, cookies readable by JS |

The Resideo integration is the reference pattern: the user types their PIN into the web or iOS UI, the client `PUT`s it to `/api/alarm/config`, the server stores it in `config.json`, and from then on neither client ever sees the PIN again — they only see panel state.

### Hard rules

1. **Never hardcode a real secret.** Placeholders and empty-string defaults in `server/src/config.ts` are fine; real values go in `config.json` or environment variables. "I'll fix it later" is how secrets get pushed.

   **Narrow exception — community-reverse-engineered vendor client constants.** Some integrations in this repo (MyQ, GE SmartHQ) have no published official API and require OAuth `client_id` / `client_secret` values extracted from the vendor's own mobile app by the open-source community. These values are already public — every forked FOSS integration hardcodes the same ones, and moving them to a config file produces zero security benefit while making fresh clones unable to run without sourcing the same public constant from somewhere else. They are permitted inline **only if all of the following hold**:

   - The secret is the vendor's mobile-app client credential, not a per-user credential.
   - An equivalent value is already public in at least one well-known open-source project (gehome, pymyq, etc.).
   - An inline comment immediately above the declaration states the provenance in one line, e.g. `// Community-reverse-engineered from the iOS MyQ app; same value as pymyq.`
   - The declaration is `private` (Swift) / not exported (TS) — no need to widen its visibility.
   - Per-user tokens, refresh tokens, passwords, and PINs obtained *using* these client credentials are still server-side / Keychain only, never committed.

   Current standing exceptions under this carve-out (keep this list current — if you add or remove one, update here in the same commit):
   - `ios/LutronHome/LutronHome/MyQManager.swift` — `clientId` / `clientSecret` for Chamberlain MyQ
   - `ios/LutronHome/LutronHome/SmartHQManager.swift` — `clientId` / `clientSecret` / `redirectURI` for GE Brillion

   Any other hardcoded secret needs a full move to config, no exceptions.
2. **`git add -A` and `git add .` are banned for any change that touches `server/data/`, `ios/LutronHome/LutronHome/`, or the repo root.** Stage files by name. The gitignore is a safety net, not a license to stage blindly — a new file type you haven't seen before may not match any existing ignore pattern.
3. **Before committing, diff the staged changes for secret shapes.** Run `git diff --cached` and scan for: long base64/hex strings, `-----BEGIN`, `Bearer `, `sk-`, `sk-ant-`, email+password pairs, 4–8 digit PINs next to a username, anything that looks like a JWT. If you see any of those in a file that isn't a gitignored config, stop.
4. **The web client never handles raw credentials in memory longer than the single form submission that sends them to the server.** No localStorage, no cookies, no Redux persistence, no logging. On iOS, sensitive values go through Keychain — not `UserDefaults`, not `@State` that survives backgrounding, not `print()`.
5. **If a secret is ever committed, even once, even to a local branch you "haven't pushed yet" — rotate it.** Assume compromise. Do not attempt to rewrite history as the only remediation; rewrite *and* rotate. Note the rotation in the commit that removes the secret.
6. **New gitignore entries accompany new secret stores in the same commit that introduces them.** Adding a new integration that reads `server/data/newthing.json`? The `.gitignore` entry lands in the same PR, not "next time."
7. **`.env.example` / `config.example.json` files are the correct way to document required keys** — they go in the repo with placeholder values and comments, while the real `.env` / `config.json` stays ignored.

### Reference incidents

- `a35de99` — "Remove TLS certificates from tracking; tighten gitignore." TLS certs had been committed. They were removed and the gitignore was hardened. Those cert values should be treated as leaked; regenerate before any public deploy.

### Known gotcha: adding a Swift file

iOS Swift files must be registered in `ios/LutronHome/LutronHome.xcodeproj/project.pbxproj` (`PBXBuildFile`, `PBXFileReference`, and the `Sources` build phase) or Xcode will silently drop them from the build, and the feature will compile-succeed while being completely absent at runtime. This bit us once already with `TotalConnectManager.swift` (fix in commit `79e6786`). If you add a Swift file and the feature doesn't show up, check the pbxproj first.

## iOS Simulator testing

Primary simulator build command (iPhone 17; iPhone 16 is no longer in the default simulator set on this machine):

```
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### MCP options for simulator automation

- **XcodeBuildMCP** — full Xcode integration (build, test, screenshot, UI automation, debugger attach):
  ```
  brew tap getsentry/xcodebuildmcp && brew install xcodebuildmcp
  claude mcp add XcodeBuildMCP -- npx -y xcodebuildmcp@latest mcp
  ```
- **iOS Simulator MCP** — lightweight simulator control (tap, type, swipe, screenshot, install, launch):
  ```
  claude mcp add ios-simulator npx ios-simulator-mcp
  ```

### Manual `simctl` reference

```
xcrun simctl list devices                           # list simulators
xcrun simctl boot "iPhone 17"                       # boot one
open -a Simulator                                   # open the Simulator app
xcrun simctl install booted /path/to/LutronHome.app
xcrun simctl launch booted com.jasongelman.LutronHome
xcrun simctl io booted screenshot /tmp/lh.png
xcrun simctl io booted recordVideo /tmp/lh.mp4
```

`simctl` does not support direct touch events — use one of the MCP servers above for UI automation.

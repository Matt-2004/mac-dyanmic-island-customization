# Isle — Progress

No SPEC.md exists in the repo; the milestone list in the original request is the spec.
Design choices not covered by it (sizes, timings, colors) are documented here.

## Milestone 1 — Scaffold + notch window ✅ (UI confirmed by user)

### Done
- `project.yml` (XcodeGen 2.46): macOS 14+ app target `Isle`, bundle id `com.wai.Isle`,
  automatic signing with team `G9BDJ48H5Z`, hardened runtime, Info.plist and entitlements
  generated from project.yml. `Isle.xcodeproj` is generated and git-ignored.
- Menu-bar agent (`LSUIElement`, `.accessory` activation policy), pure AppKit entry point
  (`Isle/App/main.swift`).
- Entitlements: `app-sandbox = false`, `automation.apple-events = true`.
- Settings window skeleton (General: hover delay + notification duration; About).
- `NotchPanel`: borderless, non-activating, transparent, level `mainMenu + 3`, joins all
  Spaces, works beside full-screen apps, never becomes key.
- `NotchGeometry`: notch size from `safeAreaInsets.top` + `auxiliaryTopLeft/RightArea`;
  prefers the screen with a notch, falls back to the main screen with a simulated
  200×menu-bar-height notch (idle state is hidden there).
- Repositions on screen parameter changes, wake, and Space changes (debounced 150 ms).
- Panel ignores mouse events except while the pointer is over the island's current shape,
  so the menu bar under the transparent area stays clickable.
- `IslandStateStore` with four derived states — `idle`, `compact`, `expanded`, `peek` —
  and priority rules (peek > expanded > compact > idle; peek restores the previous state).
- Spring animations (response 0.42, damping 0.8) for size, corner radii and content.
- Hover on compact → expands after the hover delay; leaving collapses after 0.3 s;
  click toggles. Hovering a peek pauses its auto-dismiss.
- Debug menu (menu bar icon → Debug) to force each state, with a working in-memory
  debug player (play/pause/next/previous/scrub really change the sample track).

### How to test
```sh
./scripts/run.sh          # xcodegen + xcodebuild + launch
```
or `xcodegen generate && open Isle.xcodeproj`, then Run (⌘R).

1. A capsule icon appears in the menu bar. Nothing else changes at the notch (idle = invisible, same size as the notch).
2. Icon → Debug → **Compact** (⌥⌘2 while the menu is open): black wings grow out of both sides of the notch — gradient artwork on the left, animated equalizer bars on the right.
3. Hover the wings ~0.25 s → expands into the player (artwork, title/artist, scrubber, ◀◀ ▶ ▶▶). Move away → collapses back to compact. Buttons and scrubbing work on the sample track.
4. Debug → **Expanded**: player opens and stays pinned (click the island to collapse).
5. Debug → **Notification Peek**: a banner with the Messages icon drops below the notch for 4 s, then returns to the previous state. Hover keeps it open; ✕ dismisses.
6. Debug → **Idle**: island shrinks back into the notch.
7. Debug → **Use Live Data**: clears debug overrides (live data arrives in Milestone 2).
8. Settings… opens the settings window; Quit Isle quits.

### Known issues
- Repo lives under `~/Documents`; building with `-derivedDataPath` inside the repo fails code
  signing ("resource fork, Finder information, or similar detritus") because of extended
  attributes. Use the default DerivedData location (the run script does).
- On displays without a notch, idle is invisible and other states draw from the top-center of the menu bar.
- Multi-display / lid-closed behavior not verified yet.

## Milestone 2 — Apple Music ✅ (confirmed by user)

### Done
- `MusicService`: listens to the `com.apple.Music.playerInfo` distributed notification and
  Music launch/quit; reads full state with AppleScript on a private serial queue
  (`AppleScriptRunner`, compiled scripts cached). Main thread never blocks on Apple Events.
- Never launches Music.app: every script starts with `if application "Music" is running`.
- Controls: play/pause, next, back (restart-or-previous like Music), seek via scrubber.
  Play/pause and seek update the UI optimistically, then re-sync.
- Position re-synced every 5 s while playing (catches seeks made inside Music.app);
  the UI extrapolates between syncs.
- Artwork fetched once per track (`raw data of artwork 1`), decoded off-main, cached
  (`NSCache`, 30 tracks), with an accent color from the dominant vivid hue (used for the
  equalizer bars, scrubber fill and artwork glow). Grayscale art → near-white accent.
- Fully automatic states (user request): **playing → compact**, **paused / stopped / Music
  closed → idle**, hover compact → expanded, leave → back. While expanded the island stays
  open if you pause from it, and collapses to idle when the pointer leaves.
- Menu bar menu shows `Music: <status> · <track>` and a **Grant Automation Access…** item
  when permission is denied. Logs to the unified log (subsystem `com.wai.Isle`, category `music`).
- Debug menu still exists but is optional; live data is the default.

### How to test
1. `./scripts/run.sh`
2. Play a song in Music → macOS asks *"Isle" wants access to control "Music"* → **Allow**.
   (If you clicked Don't Allow: System Settings → Privacy & Security → Automation → Isle → enable Music.
   To re-prompt from scratch: `tccutil reset AppleEvents com.wai.Isle`.)
3. Checks: play → compact; pause in Music → idle; hover → expanded; ▶/⏸, ▶▶, ◀◀, scrubbing;
   change position inside Music.app (island catches up within ~5 s); quit Music → idle;
   Music open with nothing playing → idle; Isle must not relaunch Music after you quit it.
4. Logs: `log stream --predicate 'subsystem == "com.wai.Isle"' --info`

### Known issues
- Radio/streams without duration: scrubber shows 0:00 and seeking does nothing.
- Some streaming (non-library) tracks expose no artwork via AppleScript → note-icon fallback.
- The first AppleScript call blocks its background queue until the permission prompt is answered.

## Milestone 3 — Notifications (Accessibility) ✅ (confirmed by user; real Messages peek seen in isle.log)

### Done
- `NotificationSource` protocol; `AccessibilityNotificationSource` attaches an `AXObserver` to the
  `NotificationCenter` process (`com.apple.notificationcenterui`) on a dedicated run-loop thread
  (window created / created / destroyed / layout / value changed) plus a 1 s poll fallback.
  AX messaging timeout 1 s; nothing AX runs on the main thread. Re-attaches if NotificationCenter relaunches.
- `BannerParser`: innermost element with subrole `AXNotificationCenterBanner*`/`AXNotificationCenterAlert*`,
  fallback to groups with `title`/`body` static-text identifiers; app name from the banner description,
  mapped to a bundle id via running apps / Applications folders.
- Diffing: a banner is reported once when it appears; first scan after attach is seeded silently;
  banners inside the open Notification Center panel (tall window) and bursts of >3 are ignored.
- `NotificationCoordinator`: blocklist filter, 5 s duplicate suppression, last-20 history (memory only),
  peek presentation (click peek → opens the app; ✕ dismisses).
- Accessibility onboarding window (shown at launch until granted or "Not Now"), auto-detects the grant.
- AX debug dump: Settings → Notifications → Debugging toggle (or `defaults write com.wai.Isle axDumpEnabled -bool true`)
  writes every tree change to `~/Library/Logs/Isle/ax-dump.txt` with the parser's result; rotates at 5 MB.
  Menu: Debug → Dump Notification AX Tree Now.
- Menu bar: Recent Notifications submenu (open / Clear All); Settings → Notifications: history with
  dismiss + block, blocked-apps list with Unblock.

### How to test
1. Grant Accessibility (onboarding window → Open System Settings → enable Isle).
2. Send yourself an iMessage (or any app notification) while the banner style is "Banners"/"Alerts".
3. Expect a peek under the notch; check Settings → Notifications → Recent.
4. Inspect `~/Library/Logs/Isle/ax-dump.txt` (`--- parser ---` lines show what was extracted).

### Known issues
- Iteration result: on macOS 26 banners live in a full-screen `AXSystemDialog` window, so the original
  "tall window = history panel" rule rejected every banner. Replaced with the `widgets-overlay-view`
  size check plus a 10-minute seen-memory. Panel-open behavior itself is still unverified.
- Added `~/Library/Logs/Isle/isle.log` (events only, no notification text).
- Focus modes / Do Not Disturb suppress banners, so Isle sees nothing either.
- Notifications with "None" banner style never appear on screen and cannot be captured.

## Milestone 4 — Polish ✅ build verified (Debug + Release), awaiting user testing

### Done
- Settings → General: **Launch at login** (`SMAppService.mainApp`, handles "requires approval"),
  hover delay, Reduce Motion status.
- Settings → Notifications: blocklist with **Add App…** (pick any .app) and Unblock, plus block from
  the recent list; peek duration; usernoted fallback toggle with status and a Full Disk Access shortcut.
- **Reduce Motion**: spring → 0.18 s ease, content transitions → crossfade, equalizer bars static,
  no hover scale on transport buttons.
- **Priority rules** (`IslandStateStore`): peek > expanded > compact > idle, derived rather than set,
  so a peek always restores what was there before. Peeks queue. A pointer that was already resting on
  the island when a peek arrives no longer holds it open; only deliberate hovering does.
- **usernoted fallback** (`UsernotedNotificationSource`), off by default: read-only SQLite, 2 s poll
  of `record` rows newer than the max at start, plist `req.titl/subt/body`. Schema and plist keys were
  verified on this Mac (macOS 26). Duplicate merge with the Accessibility source: same app + title + body
  within 10 s.
- README.md: run steps, permissions, how it works, diagnostics, known limitations.
- AX dump mode turned back off (`axDumpEnabled = false`).
- Fix from your real notifications: Gmail/Messenger browser web-app banners were showing as
  "Notification" with the wrong text. These banners put the app name in `title` and "Notification"
  in `body`, so Isle now rebuilds app / sender / message from the banner description. The app lookup
  also searches `~/Applications/<Browser> Apps.localized/`.
- Verified after relaunch: Accessibility grant survived the rebuild, and an `osascript` banner peeked
  as Script Editor (`isle.log`).

### How to test
1. `./scripts/run.sh`
2. Settings → General → toggle *Launch Isle at login* → check System Settings → General → Login Items.
3. Change the hover delay to 1.0 s and hover the compact island; expansion should be noticeably slower.
4. Turn on System Settings → Accessibility → Display → Reduce motion, then play music, hover, and
   trigger a notification (`osascript -e 'display notification "x" with title "y"'`): fades, no bounce,
   static bars.
5. Priority: play music → trigger a notification → peek replaces the wings → after 4 s the wings return.
   Same while expanded (hovering): peek shows, then the expanded player returns.
6. Blocklist: Settings → Notifications → Add App… → pick Script Editor → the `osascript` notification
   no longer peeks.
7. Fallback: enable *Also read the usernoted database* → status shows *Needs Full Disk Access* → grant
   it to Isle → Retry → status *Reading usernoted database*.

### Known issues
- See README "Known limitations".
- Launch at login from a Debug build in DerivedData registers that path; use an archived/exported
  build in /Applications for day-to-day use.

## Follow-up — notification app icons ✅ build verified, awaiting user check
- `AppIconProvider` + `AppIconView`. Icon order: bundle ID → app found by name (including
  `~/Applications/<Browser> Apps.localized`) → known system names (Login Items → System Settings) → the
  website's icon for web services (`WebServiceDirectory`: Messenger, Gmail, WhatsApp, Discord, Slack,
  Telegram, Instagram, …; unknown one-word names are tried as `<name>.com`) → coloured letter badge.
- Web icons: the page's `<link rel="…icon…">` tags are parsed and the best one chosen
  (apple-touch-icon > largest size, SVG last), falling back to /apple-touch-icon.png and /favicon.ico.
  Icons are normalised to PNG and cached in `~/Library/Caches/com.wai.Isle/icons`. Failures are retried
  after 1 h. This can be turned off with Settings → Notifications → Icons.
- Verified outside the app: messenger.com, mail.google.com, discord.com and instagram.com icons all
  download and decode.
- Debug → Notification Peek now alternates between a Messages sample and a Messenger web sample.

## Milestone 5 — Power and AirPods peeks 🚧 builds pass (Debug + Release); awaiting user testing

### Done
- **PowerService** (`Isle/Power`, `@Observable`): `IOPSNotificationCreateRunLoopSource` for change events.
  `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription` are read on a utility queue for percent
  (current / max), charging, AC state, charged, time to full and time to empty. Events: plugged in,
  unplugged, fully charged (once per plug-in), and low battery at 20 % / 10 % (only unplugged, once per
  discharge, re-armed above 22 % / 12 %). The first reading sets baselines silently.
- **BluetoothService** (`Isle/Bluetooth`, `@Observable`): `IOBluetoothDevice.register(forConnectNotifications:)`
  plus per-device `register(forDisconnectNotification:)`. Replayed connect events for devices already
  connected in the first 3 s are not announced.
  - AirPods are identified by name, with a fallback to the paired-device info (Apple vendor 0x004C +
    Headphones). The "All audio devices" setting also accepts Bluetooth audio-class devices and
    headset / speaker types.
  - Batteries come from `system_profiler SPBluetoothDataType -json` on a background queue (concurrent
    requests share one run). It runs 2 s after connect, every 60 s while connected, and when the island
    expands (if older than 15 s). Last values are cached and merged, so a closed case keeps its last level.
    Missing fields show "--".
  - Parser verified against this Mac's real output: AirPods L 100 / R 100 / Case 82; other devices "--".
  - Bluetooth permission: `CBManager.authorization`. A `CBCentralManager` is created only to trigger the
    first prompt. If denied, an onboarding window appears (also reachable from the menu and Settings).
    `NSBluetoothAlwaysUsageDescription` added. No private frameworks, no BLE scanning.
- **Island**
  - New states `powerPeek` and `airpodsPeek` use the same spring and transitions as the notification peek.
  - Power peek: battery glyph with fill and bolt, headline, "Charging, 1h 20m to full" / "Unplugged" /
    "Fully charged" / low battery text, and the percent. Live power peeks update while on screen.
  - AirPods peek: device symbol, name, and L / R / Case rings (single-battery devices get one ring).
    Disconnect shows a short "Disconnected" peek (2 s).
  - Compact while charging (setting): with music, a green bolt next to the equalizer; without music,
    the percent on the left and a green charging ring on the right.
  - Expanded: a Devices row (Mac battery + connected audio devices). Without music it shows "Not Playing"
    with Open Music.
- **Priority** (`IslandStateStore`, `PeekItem`): notification (4) > critical 10 % battery (3) >
  AirPods (2) > power (1). A higher peek pre-empts the active one, which is re-queued. The queue holds at
  most 3 (ordered by priority, then age), and items older than 10 s are dropped when dequeued. The
  previous state is restored afterwards.
- **Settings → Devices**: charging peek, low battery alerts, charging indicator, AirPods peek,
  AirPods-only vs all audio devices, Bluetooth permission status, connected devices with batteries.
- **Debug menu**: Peek: Charger Plugged In / Unplugged / Fully Charged / Low 20 % / Low 10 % /
  AirPods Connected / Disconnected (they go through the real queue).

### Not yet verified (needs the user)
- Real plug/unplug, fully charged, low battery, AirPods connect/disconnect, Bluetooth permission prompt,
  visuals.

### Interpretation notes
- "Every 60 s while connected and while island is expanded": polls every 60 s while connected, plus an
  immediate refresh when the island expands (throttled to 15 s).
- "Compact state while charging" uses `isCharging` (not just plugged in), so the island goes idle again
  when the battery is full or charging is paused (e.g. Optimized Charging at 80 %).

## Hardening pass — "fix the weak spots" ✅ builds + 30 unit tests pass; live checks pending

| Weak spot | Fix |
|---|---|
| Identical repeat messages suppressed for 10 min | Banners tracked by AX identifier (`id:`), content fingerprint only as fallback; coordinator merges only *cross-source* duplicates within 10 s. |
| Web-app messages with commas split wrong | `rebuildFromDescription` splits only sender from message; commas in the message survive (tested). |
| Double banners (system + Isle) | Optional *Close the system banner* (Settings → Notifications) presses the banner's Close action 0.4 s after the peek. Off by default. |
| Notification Center panel open | Unchanged detection (`widgets-overlay-view`), now covered by a fixture test; still needs a live check. |
| Focus / DND blind spot | Not fixable via Accessibility (no banner is drawn). The usernoted fallback covers it with Full Disk Access. |
| Wrong guessed web icons | `<name>.com` guesses are only used when the page's title / og:site_name / application-name mentions the app. |
| Apple Music only | Spotify support (toggle in Settings → General); picks whichever player is playing. |
| 5 s seek lag | 1 s re-sync while the player is expanded. |
| Missing covers | iTunes Search API lookup by title + artist (toggle). |
| Radio 0:00 scrubber | LIVE label instead of a scrubber when the track has no duration. |
| Full-screen apps | Island fades out over full-screen apps (peeks still show). Setting: *Hide in full-screen apps*. |
| No tests | `IsleTests` target, 30 tests: state priority/queue/stale/clicks, banner parser fixtures, Bluetooth / power / icon / iTunes / usernoted / NowPlaying parsing. |
| Debug build only, login item points at DerivedData | `scripts/install.sh` → Release into `/Applications`. Re-toggle launch at login once afterwards. |
| Nothing committed | Committed on branch `feature/isle-app`. |

### Still needs a live check by you
- Milestone 5 (plug/unplug, AirPods, Bluetooth prompt) — still awaiting your confirmation.
- Notification Center panel open, *Close the system banner*, full-screen hiding, Spotify, iTunes covers,
  LIVE label on a radio station, multi-display.

### Cannot be fixed in code
- Focus / DND: nothing is drawn, so Accessibility sees nothing (use the usernoted fallback).
- AirPods battery freshness is limited by how often macOS updates `system_profiler`.

## Background service ✅ confirmed by user (starts by itself after restart + login)

User request: run Isle like a built-in macOS service instead of an app you have to open.

### Done
- Launch agent `com.wai.Isle.agent` shipped inside the bundle (`Contents/Library/LaunchAgents`), registered
  with `SMAppService.agent`: `RunAtLoad`, `KeepAlive { SuccessfulExit = false }` (crash → restart, Quit →
  stays off until next login), `LimitLoadToSessionType Aqua`, `ProcessType Interactive`.
- Registered automatically on launch when Isle runs from `/Applications` (never from DerivedData).
  The old `SMAppService.mainApp` login item is removed, so Isle can't start twice at login.
- `SingleInstance`: the service instance asks other copies to quit (distributed notification, then
  force-quit after 4 s); opening the installed app while Isle runs shows Settings in the running copy.
- Settings → General: *Run Isle as a background service* (with live status / approval button),
  *Show icon in menu bar*.
- `scripts/install.sh`: atomic swap of `/Applications/Isle.app`, then `launchctl kickstart -k` if the
  service exists, otherwise first launch registers it.
- Unit tests no longer write into the real `isle.log`.

### Verified here
- First install: app registered the service, launchd started it (`launchctl print` → running), and
  Accessibility was still trusted.
- `kill -9` of the service → launchd restarted it (runs = 2). Reinstall → restarted on the new build (runs = 3).

### How to test
1. Stop the Xcode-run copy (⌘. in Xcode), which is older code that doesn't answer the quit request.
2. Log out and back in (or restart): the island is there without opening anything.
3. Settings → General shows *Running as a background service*. Toggle *Show icon in menu bar* off,
   then open Isle from Spotlight → Settings appears.
4. *Quit Isle* → it stays off until next login. Restart now with
   `launchctl kickstart gui/$(id -u)/com.wai.Isle.agent`.

## Battery wing ✅ builds + 32 tests pass; visuals awaiting user check

User request: hide the macOS menu bar battery and always show battery % + icon right of the notch.
- New `.battery` state (replaces idle when the Mac has a battery and *Always show battery* is on, default on).
  Grows only to the right (`IslandLayout.centerOffset`), left edge stays on the notch; display-only, clicks pass through.
- Compact with music: equalizer then "87% ▭" in the right wing (wing widened by 46 pt). The old
  compact charging indicator is used only when the battery wing is off.
- Colors: white; green + bolt while charging; orange ≤ 20 %; red ≤ 10 %.
- Updates only on `IOPSNotificationCreateRunLoopSource` callbacks; no timers or animation while idle.
- To hide the macOS battery: System Settings → Control Center → Battery → Don't Show in Menu Bar.

## Efficiency pass ✅ measured on this Mac

| | Before | After |
|---|---|---|
| Idle CPU (12 s `top`) | 0.5–2.3 % | 0.0 % |
| Memory | 35 MB | 34 MB |
| Notification → peek | same second | same second (callback coalescing 150 → 50 ms) |

- Root cause (from `sample`): every scan read the whole AX tree of the desktop widgets (Clock, Forecast,
  Status) that live in the NotificationCenter process, and the clock widget's minute tick triggered extra scans.
  Widget windows are now classified once (cached per window) and skipped; only the banner window is read.
- Global mouse monitor: no Task allocation, early exit while the pointer is below the island.
- Equalizer redraw 20 → 15 fps while music plays (nothing redraws while idle).

## Hand gestures (hold left ⌥) ✅ builds + 37 tests pass; camera use awaiting user test

- `GestureLauncher`: permanent monitor is `flagsChanged` only (fires on modifier changes, not typing). Left ⌥
  (device flag 0x20) alone → camera on; release, ⌘/⌃/⇧ added, any key, or any click → camera off.
  Key/click monitors exist only while ⌥ is held.
- `HandGestureCamera`: built-in camera only (never iPhone Continuity Camera), 640×480 native YUV, 15 fps
  requested from the sensor, late frames dropped, Vision capped at ~15 runs/s, one hand. A sign must hold
  for 3 frames; then the app opens and the camera stops immediately. A press-and-release before the camera
  starts never turns it on. Session + model are freed after 2 min unused.
- Benchmark on this M3 (no camera): ~2 ms per frame of hand detection, ~1–2 % of one core at 15 fps,
  model load 69 ms (4.5 s the very first time ever). Idle cost after install unchanged: 0.0–0.2 % CPU, 27 MB.
- Signs: ☝️ index only → VS Code, ✌️ index + middle → Terminal, 🖐️ four fingers up → Teams. Classifier
  compares tip vs PIP distance from the wrist (ratio 1.2), unit-tested with synthetic hands.
- Island state `.gesture` (highest priority while held): green camera dot + hand on the left, the sign and
  target app on the right; "Opening …" stays 1.2 s.
- Settings → General → Hand gestures (toggle, mapping, camera permission status). Camera entitlement +
  `NSCameraUsageDescription` added.

### How to test
1. Hold left ⌥ → the island shows wings with a green dot; macOS asks for camera access the first time → Allow
   (then release and hold again).
2. While holding, raise ☝️ toward the camera → VS Code opens; ✌️ → Terminal; 🖐️ → Teams.
3. Release ⌥ without a sign → the green camera light goes off at once.
4. Type ⌥E (é) or ⌥-click → no gesture; the camera stops immediately.

## User confirmations + charging animation
- Confirmed by user: AirPods peek, battery wing, hand gestures.
- Charger plug-in: the battery icon now animates from normal to charging (fill fades to green, bolt pops in
  with a small spring; crossfade with Reduce Motion). The power peek first shows the previous state, then
  animates after it opens; unplugging animates the other way. The percent text animates its digits.
- Fix (user report: "charging still shows as normal"): macOS reports the charger as connected at once but
  `IsCharging` only a few seconds later (or never while charging is paused/limited). The battery icon now
  uses `isPluggedIn` (`PowerSnapshot.showsChargingStyle`), like the menu bar battery.
- Smoother: the bolt stays in the view tree and animates scale/opacity (spring in, 0.28 s ease-out away, no
  bounce on unplug); the peek waits 0.5 s (until it has finished opening) before animating the change.
- Fix (user report: label said "Plugged in, not charging" while the icon showed charging): for 15 s after
  plug-in, "AC power but not charging yet" is labelled "Charging…" (`isStartingToCharge`), and the battery is
  re-read at 0.5/1/2/3/5/8/12/15.5 s after plug-in (stops once charging is confirmed) so the real status and
  time to full replace it quickly. After 15 s a genuine pause/limit still reads "Plugged in, not charging".

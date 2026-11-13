# Isle

**A Dynamic Island for the MacBook notch.**

Isle turns the notch into a live, animated island. It shows what's playing, drops your
notifications out of the notch, shows charging and battery at a glance, announces your
AirPods, and opens apps when you show a hand sign to the camera. It runs quietly in the
background as a macOS service: no Dock icon, nothing to open, near-zero CPU while idle.

- macOS 14 or later · Apple silicon or Intel
- Designed for MacBooks with a notch (on other displays the island hangs from the top-center of
  the menu bar)
- Native Swift: AppKit + SwiftUI, no third-party dependencies

---

## Features

### 🎵 Now playing — Apple Music & Spotify
- While music plays, the album art sits left of the notch and animated equalizer bars sit right,
  tinted with the artwork's colour.
- Rest the pointer on the island and it expands into a full player: artwork, title, artist,
  a draggable scrubber, and previous / play-pause / next.
- Follows Apple Music and Spotify. Isle never launches either player by itself.
- Missing album covers can be looked up on Apple's public iTunes Search API (title + artist only;
  can be turned off).
- Radio and live streams show a **LIVE** label instead of a scrubber.

### 🔔 Notifications in the notch
- Every notification banner drops out of the notch with the app's real icon, the sender and the
  message. This includes browser web apps such as Messenger, Gmail and Discord, which get their
  website's icon.
- Optionally closes the macOS banner the moment Isle shows it, so you only see one.
- Click a peek to open the app, or ✕ to dismiss it. Hovering keeps it open while you read.
- Keeps the last 20 notifications in *Recent Notifications* (memory only). You can also block apps.

### 🔋 Battery, always visible
- When the island has nothing else to show, the battery percent and icon sit to the right of the
  notch, like the menu bar battery. You can hide the system battery icon and use this instead.
- Plugging in animates the icon to charging: the fill turns green and a ⚡ springs in. Unplugging
  animates back.
- Peeks for *charger connected*, *unplugged*, *fully charged*, and *low battery* at 20 % and 10 %.
  Each shows the time to full or the time left.
- Colours: white normally, green while charging, orange at 20 % or below, red at 10 % or below.

### 🎧 AirPods
- Connecting or disconnecting AirPods shows a peek with **Left / Right / Case** battery rings.
- Optionally covers any Bluetooth headphones or speaker.
- The expanded player has a Devices row with the Mac battery and connected audio devices.

### ✋ Hand gestures — hold left ⌥ Option
Hold the **left Option key**, show a hand sign to the camera, and the app opens:

| Sign | Opens |
|---|---|
| ☝️ one finger | Visual Studio Code |
| ✌️ two fingers | Terminal |
| 🖐️ open hand | Microsoft Teams |

- The camera is on **only while you hold the key**. It turns off the moment you let go or a sign
  is recognised.
- Typing (e.g. ⌥E → é) or clicking while holding ⌥ cancels at once, so normal Option shortcuts keep
  working.
- Recognition uses Apple's on-device Vision hand-pose model. Frames are processed in memory and
  never saved or sent anywhere.

### ⚙️ Runs as a background service
- Installed in `/Applications`, Isle registers itself as a per-user **launchd agent**. macOS
  starts it when you log in and restarts it automatically if it ever crashes.
- No Dock icon. The menu bar icon is optional; when it's hidden, opening Isle from Spotlight shows
  its Settings.
- Hides over full-screen apps (peeks still show) and respects **Reduce Motion**.

---

## Install

You need **Xcode 16 or later** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone <this repository>
cd <repository folder>
./scripts/install.sh
```

`install.sh` builds a Release version, installs it as `/Applications/Isle.app` and starts it.
On first launch it registers the background service. From then on it starts by itself at every
login. Run `install.sh` again any time to update: it swaps in the new build and restarts the
service.

> **Signing:** `project.yml` uses automatic signing with a specific development team
> (`DEVELOPMENT_TEAM`). Change it to your own team before building. Keep a stable signing identity:
> macOS ties the Accessibility, Camera and Automation permissions to the app's signature, and
> ad-hoc builds lose them on every rebuild.

### Permissions

macOS asks for each permission the first time the feature needs it. Everything stays on your Mac.

| Permission | Used for | Where to change it |
|---|---|---|
| **Accessibility** | Reading notification banners; detecting the left ⌥ key | Onboarding window at first launch, or System Settings → Privacy & Security → Accessibility |
| **Automation → Music / Spotify** | Reading the current track and controlling playback | System Settings → Privacy & Security → Automation → Isle |
| **Bluetooth** | AirPods connect / disconnect | System Settings → Privacy & Security → Bluetooth |
| **Camera** | Hand gestures, only while left ⌥ is held | System Settings → Privacy & Security → Camera |
| **Background item** | Starting at login as a service | System Settings → General → Login Items → *Allow in the Background* |
| **Full Disk Access** *(optional)* | Fallback notification source (off by default) | System Settings → Privacy & Security → Full Disk Access |

Isle is not sandboxed. It needs Apple Events to talk to Music and Spotify, and Accessibility to
read Notification Center.

---

## Using Isle

The island changes shape automatically. You never have to switch modes.

| State | When |
|---|---|
| **Idle** | Nothing to show. Matches the notch exactly, so it's invisible. |
| **Battery** | Idle on a MacBook: battery percent and icon to the right of the notch. Clicks pass through to the menu bar. |
| **Compact** | Music is playing: artwork on the left, equalizer and battery on the right. |
| **Expanded** | Pointer rests on the compact island (0.25 s by default). Full player + devices. Collapses when the pointer leaves. |
| **Notification peek** | A notification arrives. Shows for 4 s (configurable). |
| **Power peek** | Charger connected / unplugged, fully charged, low battery. |
| **AirPods peek** | AirPods connected / disconnected, with battery levels. |
| **Hand gesture** | While left ⌥ is held: green camera dot, plus the sign and app Isle sees. |

**Priority:** hand gesture > peeks > expanded > compact > battery > idle. A peek temporarily
replaces what was showing, and the island returns to it afterwards. Among peeks:
notification > critical battery (10 %) > AirPods > other power events. A more important peek
interrupts a less important one, which comes back afterwards. At most 3 wait in line, and anything
older than 10 s is dropped. Charger peeks always show the *current* state: plugging in and out
quickly updates one peek in place instead of queueing several.

### Settings

Open **Settings…** from the menu bar icon, or open Isle from Spotlight when the icon is hidden.

- **General:** background service (status, on/off), menu bar icon, hand gestures and camera
  access, Spotify, online covers, hover delay, hide in full-screen apps, Reduce Motion status.
- **Notifications:** on/off, Accessibility status, close the macOS banner, peek duration, recent
  notifications, blocked apps, web icons, fallback source, debugging.
- **Devices:** always show battery, charging peek, low-battery alerts, AirPods peek, AirPods-only
  vs. all audio devices, Bluetooth status, connected devices with batteries.

---

## Performance

Isle is built to sit in the background all day without you noticing it. Measured on a MacBook
Air M3:

| | |
|---|---|
| CPU while idle | **0.0 %** (`top`, 12 s sample) |
| Memory | ~30 MB |
| Notification → island | within the same second |
| Hand-sign detection | ~2 ms per frame on the Neural Engine, ~1–2 % of one core while ⌥ is held |
| Camera off after releasing ⌥ | ~0.1 s |

How it stays light:
- **Event-driven:** music, power and Bluetooth changes come from system notifications. Nothing
  polls while idle, except a cheap 1 s banner check that only looks at the banner window and skips
  desktop widgets.
- **Off the main thread:** AppleScript, Accessibility reads, IOKit, `system_profiler`, camera and
  Vision all run on background queues. The UI never waits on them.
- **Camera only on demand:** it runs only while the key is held, at 640×480 and 15 fps, and drops
  late frames. The Vision model is freed after 2 minutes unused.
- **No redraws while idle:** animations run only while something is actually changing or playing.

The camera itself takes about 1 s to power up after it has been off for a while (macOS hardware
start-up). If it was used a few seconds earlier, it starts in about 0.2 s.

---

## Privacy

- No analytics, no accounts, no network access except two optional lookups:
  - **App icons:** downloaded once from a web service's own website and cached in
    `~/Library/Caches/com.wai.Isle/icons`.
  - **Missing covers:** song title and artist sent to Apple's iTunes Search API.
- Notification text is kept in memory only (last 20) and never written to disk. The optional AX
  debug dump is the one exception, and it's off by default.
- Camera frames are analysed in memory and discarded immediately.
- The log file (`~/Library/Logs/Isle/isle.log`) records events and timings only (app names, never
  message text).

---

## How it works

```
Isle/
├── App/            Entry point, AppDelegate, settings, menu bar, background service, single instance
├── Window/         Transparent non-activating NSPanel at the notch, geometry, hover / full-screen
├── Island/         State model: derived island state + prioritised peek queue
├── Views/          SwiftUI island, player, peeks, battery wing, gesture wing
├── Music/          Apple Music / Spotify via AppleScript, artwork + accent colour, iTunes covers
├── Notifications/  Accessibility banner reader, parser, app/web icons, usernoted fallback
├── Power/          IOKit power sources → snapshots and events
├── Bluetooth/      IOBluetooth connect/disconnect, battery levels from system_profiler
├── Gestures/       Left-⌥ key monitor, camera + Vision hand pose, sign → app
├── Settings/       Settings window and onboarding
└── LaunchAgent/    launchd agent plist shipped inside the app bundle
```

- **Window:** a transparent `NSPanel` above the menu bar, positioned from the screen's
  `safeAreaInsets` and `auxiliaryTopLeft/RightArea`. It ignores the mouse except over the island's
  current shape, so the menu bar underneath stays clickable.
- **State:** `IslandStateStore` derives the visible state from its inputs (music, power, peeks,
  hover, gesture) instead of setting it directly. That way a peek always returns to whatever was
  there before.
- **Music:** `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged` distributed
  notifications trigger AppleScript reads on a serial queue. Position is re-synced every 5 s (1 s
  while expanded) and extrapolated in between.
- **Notifications:** an `AXObserver` on the NotificationCenter process (on its own run-loop thread)
  finds `AXNotificationCenterBanner` elements. Each banner is tracked by its accessibility
  identifier, so it peeks exactly once. Web-app banners are rebuilt from the banner's accessibility
  description.
- **Power:** `IOPSNotificationCreateRunLoopSource`. Right after plug-in, macOS reports "on AC, not
  charging" for a few seconds. Isle shows that as "Charging…" and re-reads a few times until
  charging is confirmed.
- **Bluetooth:** `IOBluetoothDevice` connect/disconnect notifications. Batteries come from
  `system_profiler SPBluetoothDataType -json`. No private frameworks and no BLE scanning.
- **Gestures:** a `flagsChanged` monitor watches only modifier keys, never typing. Holding left ⌥
  starts an `AVCaptureSession` on the built-in camera, and `VNDetectHumanHandPoseRequest`
  classifies extended fingers. A sign must hold for 3 frames before its app opens.
- **Service:** `SMAppService.agent` with `RunAtLoad` and `KeepAlive { SuccessfulExit = false }`:
  restarted after a crash, and a normal Quit is respected until the next login.

---

## Development

```sh
./scripts/run.sh     # generate the project, build Debug, launch
xcodegen generate && xcodebuild test -project Isle.xcodeproj -scheme Isle -destination 'platform=macOS'
```

- `Isle.xcodeproj` is generated from `project.yml` and git-ignored. Run `xcodegen generate` after
  adding or removing files.
- 40 unit tests cover the island state machine and peek queue, the notification banner parser,
  battery/power transitions, Bluetooth / icon / artwork / usernoted parsers, and the hand-sign
  classifier.
- The menu bar icon has a **Debug** menu to force every island state and peek with sample data.
- A Debug build started from Xcode takes over from the installed service. Afterwards, stop it in
  Xcode (⌘.) and bring the service back with
  `launchctl kickstart gui/$(id -u)/com.wai.Isle.agent`.
- If the repository lives in an iCloud-synced folder, keep DerivedData outside it. Otherwise
  codesign fails with "resource fork, Finder information, or similar detritus not allowed".

### Diagnostics

| | |
|---|---|
| Service status | `launchctl print gui/$(id -u)/com.wai.Isle.agent` |
| Event log | `~/Library/Logs/Isle/isle.log` (events and timings, no message text) |
| Notification Center tree | `~/Library/Logs/Isle/ax-dump.txt`, only when enabled in Settings → Notifications → Debugging. **Contains notification text**, so turn it off afterwards. |
| Unified log | `log stream --predicate 'subsystem == "com.wai.Isle"'` |

---

## Known limitations

- **Notification capture reads Notification Center's on-screen UI**, which is not a public API.
  The parser is tuned for macOS 26, and a macOS update can change that structure. Use the AX dump
  to re-tune `BannerParser`.
- With **Focus / Do Not Disturb** or banner style *None*, macOS shows no banner, so Isle sees
  nothing. The optional usernoted fallback can catch these with Full Disk Access.
- Closing the macOS banner may also remove the notification from Notification Center's list.
  Isle keeps its own recent list.
- A web-app sender name that itself contains ", " can be split incorrectly.
- Browser media (YouTube etc.) isn't supported; only Apple Music and Spotify.
- AirPods battery levels come from `system_profiler`, which macOS updates on its own schedule.
  They can lag a few minutes behind the Bluetooth menu.
- Hand gestures need decent light and a hand facing the camera. The camera's ~1 s cold start is
  hardware.
- Full-screen detection compares the front window to the screen size. Multi-display setups haven't
  been tested.

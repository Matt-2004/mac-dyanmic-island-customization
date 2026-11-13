# Isle

A menu-bar app for MacBooks with a notch. The notch becomes a live island: Apple Music playback
or Spotify when something is playing, a full player on hover, notification banners that drop out of the
notch, charging and low-battery peeks, and AirPods connect peeks with battery levels.

macOS 14+, Apple silicon or Intel. Works best on a notched display; on other displays the island
hangs from the top-center of the menu bar.

## Run

Requirements: Xcode 16+ (built with Xcode 26.5) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
./scripts/run.sh            # generates Isle.xcodeproj, builds Debug, launches Isle
```

Or `xcodegen generate && open Isle.xcodeproj`, choose the **Isle** scheme, and press ⌘R.

For daily use, install a Release build into `/Applications`:

```sh
./scripts/install.sh        # Release build → /Applications/Isle.app → launch
```

After the first install, turn *Launch Isle at login* off and on again in Settings so the login item
points at `/Applications/Isle.app` (not a DerivedData build). The Accessibility, Automation and
Bluetooth grants carry over because the signing identity is the same.

Tests (30 unit tests: priority queue, banner parser, battery/power/icon/artwork/usernoted parsers):

```sh
xcodegen generate && xcodebuild test -project Isle.xcodeproj -scheme Isle -destination 'platform=macOS'
```

- `Isle.xcodeproj` is generated from `project.yml` and git-ignored. Run `xcodegen generate`
  after adding or removing source files.
- Signing uses automatic signing with team `G9BDJ48H5Z` (set in `project.yml`). Change
  `DEVELOPMENT_TEAM` to your own team. A stable signing identity matters: macOS ties the
  Accessibility and Automation grants to the signature, and ad-hoc builds lose them on each rebuild.
- If the repo lives in an iCloud-synced folder, don't put DerivedData inside it — codesign fails with
  "resource fork, Finder information, or similar detritus not allowed".
- If Isle was started from Xcode, stop it there (⌘.) before using `run.sh`; a debugger-held instance
  can't be quit from the shell and blocks the new launch.

## What it does

| Island state | When |
|---|---|
| **Idle** | Nothing playing (paused, stopped, or Music closed). Matches the notch, so it is invisible. |
| **Compact** | Apple Music or Spotify is playing: artwork left of the notch, equalizer bars right. While charging: a bolt, or the percent and a charging ring when nothing plays. |
| **Expanded** | Pointer rests on the compact island (hover delay, default 0.25 s) or you click it. Artwork, title, artist, scrubber, previous / play-pause / next. Collapses 0.3 s after the pointer leaves. |
| **Notification peek** | A notification banner appears. Shows for 4 s (configurable). |
| **Power peek** | Charger plugged in / unplugged, fully charged, battery at 20 % / 10 %. |
| **AirPods peek** | AirPods (or, optionally, any Bluetooth audio device) connect / disconnect, with L / R / Case battery. |

Priority rules: **peek > expanded > compact > idle**. A peek temporarily replaces whatever is
showing and the island returns to it afterwards (e.g. music → peek → music). Between peeks:
notification > 10 % battery > AirPods > other power events. A higher peek interrupts a lower one
(which comes back afterwards); at most 3 wait in the queue and any older than 10 s are dropped. Hovering a peek you moved onto keeps it open; clicking it opens the
posting app; ✕ dismisses it. If you pause from the expanded player, it stays open until the pointer
leaves, then goes idle.

Reduce Motion (System Settings → Accessibility → Display) is respected: the island resizes with a
short fade instead of a spring, content crossfades, and the equalizer bars stop animating.

## Permissions

| Permission | Why | How |
|---|---|---|
| **Automation → Music** | Read the current track and position, control playback | Prompted the first time Music is running while Isle is open. Fix later in System Settings → Privacy & Security → Automation → Isle → Music. Reset with `tccutil reset AppleEvents com.wai.Isle`. |
| **Accessibility** | Read notification banners drawn by Notification Center | Onboarding window at first launch, or menu bar icon → *Set Up Notifications…*. Then System Settings → Privacy & Security → Accessibility → enable Isle. |
| **Full Disk Access** *(optional)* | Only for the usernoted fallback (off by default) | System Settings → Privacy & Security → Full Disk Access → add Isle. |
| **Bluetooth** | AirPods connect / disconnect | Prompted at first launch. If denied, *Set Up AirPods…* in the menu bar menu. |
| **Automation → Spotify** *(optional)* | Same as Music, for Spotify | Prompted the first time Spotify plays while Isle is open. |
| **Login Items** *(optional)* | Launch at login | Settings → General → *Launch Isle at login*. macOS may ask you to approve it in Login Items. |

Isle is not sandboxed (needed for Apple Events to Music and Accessibility access to another process).

## Settings

- **General**: launch at login, Spotify on/off, look up missing covers online, hover delay, hide in
  full-screen apps, Reduce Motion status.
- **Notifications**: on/off, Accessibility status, close the system banner, peek duration, recent
  notifications (last 20, memory only — open, dismiss, block app), blocked apps (Unblock, *Add App…*),
  web icons, usernoted fallback, debugging (AX tree dump).
- **Devices**: charging peek, low battery alerts, charging indicator, AirPods peek, AirPods-only vs
  all audio devices, Bluetooth status, connected devices with batteries.

The menu bar icon also shows the island and Music status, *Recent Notifications*, and a **Debug**
menu that can force each island state with a built-in demo track.

## How it works

- **Music** (`Isle/Music`): `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged`
  distributed notifications trigger refreshes. AppleScript runs on a private serial queue (never on
  the main thread) to read state, position, and artwork and to send controls. Isle never launches
  either player. With both open, the one that is playing (most recent first) wins. While playing, the
  position is re-synced every 5 s (every 1 s while the player is expanded) and extrapolated in between.
  Artwork is decoded off the main thread and cached (30 tracks); Spotify art comes from its artwork
  URL. Tracks with no artwork (some streaming tracks) get a cover from the public iTunes Search API
  (title + artist only; can be turned off). The accent color comes from the artwork's dominant vivid hue.
- **Notifications** (`Isle/Notifications`): `AccessibilityNotificationSource` observes the
  `NotificationCenter` process with an `AXObserver` on its own run-loop thread, plus a 1 s poll.
  `BannerParser` finds `AXNotificationCenterBanner` elements and reads the `title` / `subtitle` /
  `body` static texts. The app name comes from the banner description. Each banner is tracked by its
  accessibility identifier, so it peeks once when it appears, and a second identical message still
  peeks. Banners already on screen at launch, ones inside the open Notification Center panel, and
  bursts of more than 3 are ignored. Optionally, Isle presses the banner's own *Close* action after
  showing its peek, so you don't see two banners.
- **Fallback** (`UsernotedNotificationSource`, off by default): polls the usernoted SQLite database
  (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`) read-only every 2 s for new
  records. A notification seen by both sources within 10 s is shown once.
- **Power** (`Isle/Power`): IOKit power-source notifications; events are derived from transitions.
- **Bluetooth** (`Isle/Bluetooth`): IOBluetooth connect / disconnect notifications; batteries from
  `system_profiler SPBluetoothDataType -json` on a background queue. No private frameworks, no BLE
  scanning.
- **Window** (`Isle/Window`): a fixed-size, transparent, non-activating `NSPanel` above the menu bar,
  positioned from `safeAreaInsets` and `auxiliaryTopLeft/RightArea`, repositioned on screen, wake,
  and Space changes. It ignores mouse events except over the island's current shape, so the menu bar
  stays clickable. Over a full-screen app (a frontmost window covering the whole screen) the island
  fades out, except for peeks (setting).

## Diagnostics

- `~/Library/Logs/Isle/isle.log`: startup, Accessibility attach, banner detections (app names only).
- `~/Library/Logs/Isle/ax-dump.txt`: written only when *Settings → Notifications → Dump
  Notification Center AX tree* is on, or via *Debug → Dump Notification AX Tree Now*. **Contains
  notification text**, so turn it off when done.
- Unified log: `log stream --predicate 'subsystem == "com.wai.Isle"'`.

## Known limitations

- **Notification capture depends on private UI structure.** The parser was tuned on macOS 26
  (banners are `AXNotificationCenterBanner` groups in a full-screen `AXSystemDialog` window). A macOS
  update can change this; use the AX dump to re-tune `BannerParser`.
- Notifications that never show a banner (Focus / Do Not Disturb, or banner style *None*) are
  invisible to the Accessibility source. The usernoted fallback can catch them if Full Disk Access is
  granted.
- Detecting the open Notification Center panel uses the `widgets-overlay-view` element's size. This
  has not been verified with the panel open; the 10-minute "seen" memory and the burst rule are the
  backstops.
- Browser web-app notifications (e.g. Gmail/Messenger from Brave or Chrome) hide their text from the
  banner's static texts; Isle rebuilds sender and message from the banner's accessibility description
  ("App, Sender, Message…"). A sender name that itself contains ", " would be split wrongly; commas in
  the message are kept. Blocking such apps works by app name.
- Icons: installed apps use their own icon. Web services (Messenger, Gmail, Discord, …) get the
  website's public icon, downloaded once from the service's domain and cached in
  `~/Library/Caches/com.wai.Isle/icons` (can be turned off in Settings → Notifications → Icons).
  Unknown single-word names are tried as `<name>.com` and only used if that page's title or site
  name mentions the app; otherwise a coloured letter badge is shown.
- The system banner still appears in the top-right unless *Close the system banner* is on. Closing
  uses the banner's own accessibility action; it has not been verified on every macOS version.
- Radio and live streams show a LIVE label instead of a scrubber (they have no duration to seek).
- Browser media (YouTube, etc.) is not supported; Apple Music and Spotify only.
- AirPods batteries come from `system_profiler`, which macOS updates on its own schedule, so levels
  can lag a few minutes behind the Bluetooth menu.
- Full-screen detection compares window bounds to the screen; apps that hide the menu bar without
  real full screen are treated as normal windows. Multi-display setups have not been tested.
- The usernoted database is undocumented; its schema (`record`, `app`, plist keys `titl` / `subt` /
  `body`) was verified on this Mac but may change.

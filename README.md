# Basic Fan 1.0.0

[**Download Basic Fan 1.0.0 installer (.pkg)**](https://github.com/ducanhdz208/basic-fan/releases/download/v1.0.0/Basic.Fan.1.0.0.pkg)

Basic Fan retains the original SwiftUI window from version 0.3.1: the same fan cards, typography, spacing, switch, slider, and buttons, with an additional editable plugged-in RPM field. This is the official 1.0.0 release, based on RC3. It keeps the working fan-control verification, persistent helper, Dock icon, CPU-only menu-bar label, and detailed dropdown.

## Compatibility

Tested on a 16-inch MacBook Pro with M1 Max running macOS 27.0.1. This is not a general-purpose fan controller for every Mac; other hardware and older macOS versions have not been validated. The app uses private SMC interfaces.

Choose **Basic Fan → About Basic Fan** in the top-left app menu to see the current version and “❤️ Made with love by Jimmy Truong”.

## Install

1. Quit the currently running Basic Fan from its menu bar. Wait a few seconds for its helper to restore Automatic.
2. Download **Basic Fan 1.0.0.pkg** from the GitHub release, then open it and approve the update in macOS Installer.
3. Open **Basic Fan** from Applications. It starts in the menu bar without a Dock icon. Choose **Open Basic Fan…** to show the settings window and Dock icon. Close the window with its close button or **⌘W** to hide the Dock icon and keep monitoring and fan control running. Minimizing retains the Dock icon so you can restore the window.

The app and helper are a matched pair. Install the package rather than replacing only the app. Routine fan changes do not ask for your password; installing an update still needs approval.

## Adjustable plugged-in speed

In the app window, enter your desired **Plugged-in speed**, then press Return or move focus out of the field. You can also use the stepper. Enable **Fixed RPM when plugged in**:

- External power: both fans target your chosen RPM.
- Battery or unavailable power-source reading: Automatic cooling.
- Reconnecting power: your chosen RPM resumes.
- The default is 2000 RPM. The app remembers your chosen RPM after quitting.
- The field accepts only the shared range supported by both fans. This Mac reports 1499–5348 RPM for a shared target.
- Changing the value while this mode is active applies it immediately.

The manual percentage slider remains available as a separate mode. Automatic ends the session. Modes do not automatically enable themselves after app relaunch.

## Menu bar and readings

The menu bar shows only **CPU 52°C**, for example. Click it for average CPU and GPU temperatures, power status, left/right fan RPM, cooling mode, and mode controls. The Dock retains the fan icon; the menu bar has no icon.

CPU is an arithmetic average of up to 10 valid M1 CPU-core sensor readings; GPU averages up to four GPU sensors. Unavailable or invalid readings are excluded. Missing averages display a dash.

Refresh behavior:

| State | Sensor refresh |
|---|---|
| Menu or settings window open | CPU, GPU, and fan readings every second |
| Both closed, external power | CPU only every second |
| Both closed, battery | CPU only every second |
| Opening the menu/window | Immediate full refresh, followed by live updates |
| Sleeping | UI sensor polling paused |

The app prevents App Nap while monitoring so the CPU menu-bar reading continues updating when the window and menu are closed. Normal system sleep remains allowed; polling pauses during sleep and resumes on wake. One second is the requested cadence, not a hard real-time guarantee under system load. Power and thermal events are handled separately from these display intervals.

## Optimizations

- Restored the original SwiftUI window, created only when opened. Hidden views are not notified of sensor changes; visible views refresh only when displayed values change.
- Moved SMC sensor reads off the main thread.
- Cached hardware identity and fan speed limits; they are no longer re-read every second.
- Skip GPU/fan reads while those values are not visible.
- Update menu text only when it changes; avoid updating hidden UI.
- Keep CPU monitoring at one second on both power sources, with App Nap prevention that still permits system sleep. Active fan-control sessions also maintain their safety heartbeat.
- Heartbeats run every two seconds. Identical heartbeats renew the lease without rewriting fans.
- Helper uses power/thermal notifications, with a ten-second environment fallback while active.
- The helper has no periodic timer while idle. Its watchdog runs every two seconds only during an active session or pending cleanup.
- Read back stable targets periodically (five-second minimum spacing); write only when the requested target changes or the hardware has drifted away from the request.
- Builds use size optimization and whole-module optimization.

## Safety behavior

The helper restores Automatic on disconnect, explicit Automatic, or quit. A six-second heartbeat lease is checked by the two-second watchdog, so a silent client stall is normally detected within roughly eight seconds. Serious/critical thermal pressure overrides the fixed/manual setting with Automatic. Sleep notifications and large scheduling gaps also return control to macOS before resuming an eligible session.

The helper keeps retrying failed cleanup after a client disconnects. A forced kill or crash of the helper itself cannot guarantee restoration; restart the Mac if cooling control gets stuck. Avoid running a second fan controller at the same time.

Only the exact matching signed app build may call this root helper. Its interface accepts bounded fan commands, never arbitrary shell commands or filesystem paths. No password is stored and no sudo policy is changed. This release is ad-hoc signed with an unsigned installer; it is not notarized.

## Validation and measurement

- 53 sensor, policy, RPM validation, reconciliation, and scheduling checks passed.
- 31 helper lifecycle checks passed, including power transitions, heartbeat expiry, competing clients, disconnect, failed restoration, custom RPM changes, and deduplicated heartbeats.
- Installer payload, signatures, root-owned service files, and exact-build client requirement checked.
- The established SMC write and bounded verification implementation is preserved.
- Prior RC1 build: a 30-second read-only background benchmark showed approximately 100–110 MiB resident memory. CPU time increased by 0.33 seconds over the measured 20-second interval, averaging about 1.65% of one CPU core. Sampled instantaneous CPU usage ranged from 0% to 7%. These are short CPU/memory observations, not a wattage or battery-life test.
- The benchmark copy did not control fans; its full fan-active power usage and the new custom-RPM behavior need checking after installation.
- No GUI screenshot inspection was completed; the earlier computer-use capture service failed.

## Remove / rebuild

Quit the app, then run **Remove Helper.command** to remove the system helper with administrator approval. The app can then be moved to Trash.

Run `./build.sh` using full Xcode to rebuild the app and matching package. The signed app's code hash is embedded in the helper; Source/ExpectedClient.txt records it. Rebuilding means reinstalling both together.

SMC.swift is adapted from Serhiy Mytrovtsiy's MIT-licensed Stats project: https://github.com/exelban/stats/blob/master/SMC/smc.swift. Sensor mapping: https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift. Original license: Source/Stats-LICENSE and the app resources.

## Source and contributions

Build on an Apple Silicon Mac with full Xcode installed. Run `./test.sh` for the read-only policy and mocked helper tests, then `./build.sh` to build the matching app and installer. No administrator access is needed for the tests. Generated apps, packages, and code-signing metadata are excluded from source control.

Original project code is MIT licensed; the upstream Stats copyright and license are retained in `Source/Stats-LICENSE`.

## Adaptive app icon

The app includes a layered Icon Composer icon with default, dark, clear and tinted appearances, plus a generated ICNS fallback for older macOS. The system selects the appearance; the app does not force a static Dock image. Edit `Source/BasicFanIcon.icon` in Icon Composer. Building requires full Xcode; set `DEVELOPER_DIR` if Xcode is not installed at `/Applications/Xcode.app`.

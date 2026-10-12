# Technical notes

Implementation details and validation limits for Basic Fan 1.0.0.

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


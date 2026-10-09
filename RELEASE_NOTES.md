# Basic Fan 1.0.0 RC3

Release candidate for testing, not the final 1.0.0 release.

- ⌘W closes the settings window without quitting; monitoring and fan control continue.
- Launches only in the menu bar. The Dock icon appears when settings open and disappears when they close.
- About Basic Fan panel showing the current version and “❤️ Made with love by Jimmy Truong”.
- CPU average in the menu bar, refreshed every second while awake on AC or battery.
- Dropdown with CPU/GPU averages, power status, and both fan speeds.
- Editable plugged-in RPM, with automatic cooling on battery.
- Original SwiftUI settings window and minimal Dock fan icon.
- Persistent privileged helper: one administrator approval at installation, no repeated prompts for ordinary controls.
- Deferred hidden GPU/fan reads and reduced redundant fan writes.

Tested on a 16-inch M1 Max MacBook Pro running macOS 27.0.1. Other configurations are unverified. All 84 policy and mocked helper checks passed. A short read-only background test of the prior RC1 build averaged 1.65% of one CPU core and 100–110 MiB resident memory; battery impact and full fan-active power were not measured.

Quit the existing app before installing the package, then reopen Basic Fan from Applications. Install the app and helper together using the package. This build is ad-hoc signed; the installer is unsigned and not notarized, so macOS may block it. Do not disable system-wide security protections.

The helper restores automatic control on normal quit, disconnect, heartbeat expiry, and serious thermal pressure. Forced termination of the helper itself cannot guarantee restoration. Avoid simultaneous fan controllers. See README for limitations and removal instructions.

<p align="center">
  <img src="Icon.png" width="112" alt="Basic Fan app icon">
</p>

# Basic Fan

A simple macOS menu-bar fan controller. See your CPU temperature at a glance, and set a fan speed for when your Mac is plugged in.

[**Download 1.1.0 (.pkg)**](https://github.com/ducanhdz208/basic-fan/releases/download/v1.1.0/Basic.Fan.1.1.0.pkg) · [Release notes](https://github.com/ducanhdz208/basic-fan/releases/latest)

## Features

- **Live temperatures:** CPU average in the menu bar; click for CPU/GPU averages, power status, and both fan speeds.
- **Plugged-in mode:** choose your RPM, with automatic cooling on battery. Default: 2000 RPM.
- **Manual control:** adjust fan speed or return to Automatic.
- **Quiet background operation:** close settings with ⌘W; monitoring continues without a Dock icon.
- **Adaptive icon:** light, dark, clear, and tinted appearances.

## Install

1. Quit any running copy of Basic Fan.
2. Download and open the **.pkg installer**, then approve installation.
3. Open **Basic Fan** from Applications. Click the CPU temperature to get started.

Install updates using the package so the app and its helper stay matched. Routine fan changes do not require your password.

**Compatibility:** tested on a 16-inch M1 Max MacBook Pro running macOS 27.0.1. Other configurations are unverified. The installer is unsigned and the app is not notarized; macOS may block installation.

## Use

Choose **Open Basic Fan…** from the menu-bar dropdown. Enter your **Plugged-in speed** and enable **Fixed RPM when plugged in**. Your RPM is saved, but control modes must be enabled again after relaunch.

CPU readings refresh about every second while awake. GPU and fan readings refresh while the dropdown or settings are visible. Closing settings keeps the app running; **Quit Basic Fan** restores Automatic.

## Cooling safeguards

Basic Fan returns control to macOS on normal quit, connection loss, heartbeat expiry, or serious thermal pressure. A crash or forced termination of the helper itself cannot guarantee restoration; restart your Mac if control gets stuck. Avoid running another fan controller alongside it.

[Technical notes and test results](docs/TECHNICAL_NOTES.md)

## Updates and startup (1.1.0)

Open **Settings & Updates** in the menu-bar dropdown:

- **Launch at Login** starts monitoring when you sign in. Fan modes remain off until you enable them. macOS may require approval in Login Items.
- **Check for Updates…** checks the latest stable GitHub release and offers a verified installer.
- **Automatically Check for Updates** is optional and checks at most once a day. Updates still require your confirmation and macOS administrator approval.

Updates replace the app and helper in place. The updater checks GitHub’s SHA-256 digest before opening the package, never deletes the installed app itself, and removes its temporary installer only after the new app and matching helper are confirmed on relaunch. A failed or cancelled download is discarded; an installer cancelled after handoff is retained until a successful update or the next download. Preferences are preserved. macOS Installer does not provide this app with a guaranteed rollback after an interrupted installation.

## Build or remove

To build, use an Apple Silicon Mac with full Xcode installed:

```sh
./test.sh
./build.sh
```

If Xcode is installed elsewhere, set `DEVELOPER_DIR` to its `Contents/Developer` folder. Rebuild and install the app and helper together.

To uninstall, quit Basic Fan, download and run [Remove Helper.command](https://raw.githubusercontent.com/ducanhdz208/basic-fan/main/Remove%20Helper.command), approve helper removal, then move the app to Trash.

## Credits

❤️ Made with love by **Jimmy Truong**.

[MIT licensed](LICENSE). SMC code and sensor mappings are adapted from [Stats](https://github.com/exelban/stats); its [original license](Source/Stats-LICENSE) is included.

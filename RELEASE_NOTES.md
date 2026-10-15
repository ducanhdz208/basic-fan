# Basic Fan 1.1.0

- Launch at Login via macOS Login Items, available under Settings & Updates.
- Manual update checking and optional daily checks against stable GitHub releases.
- Installer download verification using GitHub SHA-256 digests and exact asset sizes.
- In-place installation of the app and matching helper through macOS Installer, with administrator approval.
- Temporary package cleanup after the updated app and matching helper are confirmed on relaunch; no deletion of unrelated files or old app bundles by the updater.

Install this version manually once to enable future update checks. Quit Basic Fan before opening the package. Existing fan settings remain saved; fan modes do not start automatically at login.

110 automated checks passed, including corrupt downloads, release filtering, version comparisons, cleanup, and symlink safeguards. Launch-at-login behavior across logout/login and the interactive installer handoff still need a live check. No full transactional rollback is provided for an interrupted macOS installation. The app remains ad-hoc signed and the installer unsigned and not notarized.

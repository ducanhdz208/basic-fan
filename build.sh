#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="Basic Fan.app"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/basicfan-build.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -Osize -whole-module-optimization -target arm64-apple-macosx13.0 -module-cache-path "${TMPDIR:-/tmp}/basicfan-module-cache" Source/SMC.swift Source/Control.swift Source/HelperProtocol.swift Source/PowerObserver.swift Source/SensorReader.swift Source/UpdatePolicy.swift Source/AppServices.swift Source/App.swift -framework AppKit -framework SwiftUI -framework ServiceManagement -framework IOKit -o "$APP/Contents/MacOS/BasicFan"
# Full Xcode is required to compile the layered icon and its legacy fallback.
ICON_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$ICON_DEVELOPER_DIR/usr/bin/actool" ]]; then
    echo "Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory." >&2
    exit 1
fi
DEVELOPER_DIR="$ICON_DEVELOPER_DIR" xcrun actool "$PWD/Source/BasicFanIcon.icon" \
    --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 13.0 --app-icon BasicFanIcon \
    --output-partial-info-plist "$BUILD/icon-info.plist" --output-format human-readable-text
cp Source/Info.plist "$APP/Contents/Info.plist"
/usr/bin/python3 - "$APP/Contents/Info.plist" "$BUILD/icon-info.plist" <<'PYICON'
import plistlib,sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: info.update(plistlib.load(f))
with open(sys.argv[1], 'wb') as f: plistlib.dump(info, f)
PYICON
cp Source/Stats-LICENSE "$APP/Contents/Resources/Stats-LICENSE"
codesign --force --sign - "$APP"
HASH="$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$HASH" =~ '^[a-f0-9]{40}$' ]]
# Generate Swift escaping without relying on shell quoting of a requirement string.
/usr/bin/python3 - "$HASH" "$BUILD/ExpectedClient.swift" <<'PY'
import json,sys
req='identifier "local.basicfan.app" and cdhash H"'+sys.argv[1]+'"'
open(sys.argv[2],'w').write('let expectedAppRequirement = '+json.dumps(req)+'\n')
PY
mkdir -p "$BUILD/root/Applications" "$BUILD/root/Library/PrivilegedHelperTools" "$BUILD/root/Library/LaunchDaemons" "$BUILD/scripts"
swiftc -swift-version 5 -Osize -whole-module-optimization -target arm64-apple-macosx13.0 -module-cache-path "${TMPDIR:-/tmp}/basicfan-module-cache" Source/SMC.swift Source/Control.swift Source/HelperProtocol.swift Source/PowerObserver.swift Source/FanEngine.swift Source/HelperMain.swift "$BUILD/ExpectedClient.swift" -framework IOKit -o "$BUILD/root/Library/PrivilegedHelperTools/local.basicfan.helper"
codesign --force --sign - --identifier local.basicfan.helper "$BUILD/root/Library/PrivilegedHelperTools/local.basicfan.helper"
ditto "$APP" "$BUILD/root/Applications/$APP"
cp Source/local.basicfan.helper.plist "$BUILD/root/Library/LaunchDaemons/"
cp Source/Installer-preinstall "$BUILD/scripts/preinstall"
cp Source/Installer-postinstall "$BUILD/scripts/postinstall"
chmod 755 "$BUILD/scripts/"* "$BUILD/root/Library/PrivilegedHelperTools/local.basicfan.helper"
chmod 644 "$BUILD/root/Library/LaunchDaemons/local.basicfan.helper.plist"
pkgbuild --root "$BUILD/root" --identifier local.basicfan.installer --version 1.1.0 --install-location / --ownership recommended --scripts "$BUILD/scripts" --component-plist Source/Components.plist "Basic Fan.pkg"
codesign --verify --deep --strict "$APP"
# Preserve the exact pinned requirement as build metadata for inspection.
cp "$BUILD/ExpectedClient.swift" Source/ExpectedClient.txt
touch "$APP"
echo "Built app and installer: $PWD/Basic Fan.pkg"

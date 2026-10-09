#!/bin/zsh
set -eu
if /usr/bin/pgrep -x BasicFan >/dev/null; then
    echo 'Quit Basic Fan from its menu bar, then run this again.'
    exit 1
fi
/usr/bin/sudo -v
if /bin/launchctl print system/local.basicfan.helper >/dev/null 2>&1; then
    /usr/bin/sudo /bin/launchctl bootout system/local.basicfan.helper
fi
/usr/bin/sudo /bin/rm -f /Library/LaunchDaemons/local.basicfan.helper.plist /Library/PrivilegedHelperTools/local.basicfan.helper
echo 'Basic Fan helper removed. You may now move the app to Trash.'

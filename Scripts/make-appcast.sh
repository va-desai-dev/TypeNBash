#!/bin/zsh
# Writes appcast.xml next to a release DMG, signed with the Sparkle key in the
# login keychain (account "TypeNBash"). Upload both files to the GitHub release
# tagged v<version>; the app's SUFeedURL reads the latest release's appcast.xml.
#
#   Scripts/make-appcast.sh ~/Desktop/TypeNBash.dmg
set -euo pipefail

dmg="/Users/vdesai/CENTCOM/BuildExport/TypeNBash.dmg"
dmg=${dmg:A}
[[ -f $dmg ]] || { print -u2 "No such file: $dmg"; exit 1 }

tools=(~/Library/Developer/Xcode/DerivedData/TypeNBash-*/SourcePackages/artifacts/sparkle/Sparkle/bin(N/))
(( ${#tools} )) || { print -u2 "Sparkle tools not found; build TypeNBash in Xcode once first."; exit 1 }

# Read the version from the app inside the DMG.
mount=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint $mount $dmg >/dev/null
app=($mount/*.app(N))
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app[1]/Contents/Info.plist")
hdiutil detach $mount >/dev/null

work=$(mktemp -d)
cp $dmg $work/
$tools[1]/generate_appcast --account TypeNBash \
    --download-url-prefix "https://github.com/va-desai-dev/TypeNBash/releases/download/v$version/" \
    -o $work/appcast.xml $work
# Target the parent folder of the Scripts directory
PROJECT_ROOT="${0:A:h:h}"

cp "$work/appcast.xml" "$PROJECT_ROOT/appcast.xml"
rm -rf "$work" "$mount"

print "Wrote $PROJECT_ROOT/appcast.xml for v$version."
print "Upload it and ${dmg:t} to the GitHub release tagged v$version."


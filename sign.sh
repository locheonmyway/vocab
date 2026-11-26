#!/bin/zsh
# Stable, local-only signing identity. Never fall back to ad-hoc signing:
# macOS would treat the next build as different code and revoke TCC access.
set -euo pipefail
bundle="$1"
selector="${VOCAB_SIGN_IDENTITY:-Vocab Local Code Signing}"
identity="$(/usr/bin/security find-identity -p codesigning | /usr/bin/awk -v name="$selector" '$2 == name || index($0, "\"" name "\"") {print $2}' | /usr/bin/sort -u)"
identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist")"
if [[ ! "$identity" =~ '^[0-9A-Fa-f]{40}$' ]]; then
    echo "Vocab local signing identity is missing or ambiguous. See docs/INSTALL.md; do not replace the installed app." >&2
    exit 1
fi
/usr/bin/codesign --force --timestamp=none --sign "$identity" "$bundle/Contents/Helpers/DictionaryBridge"
/usr/bin/codesign --force --timestamp=none --sign "$identity" "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
/usr/bin/codesign --verify -R="identifier \"$identifier\" and certificate leaf = H\"$identity\"" "$bundle"

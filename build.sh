#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
output="${1:-$(mktemp -d /tmp/vocab-build.XXXXXX)/Vocab.app}"
identifier="${2:-com.chloe.vocab}"
[[ ! -e "$output" ]] || { print -u2 "Output exists; use a fresh build path: $output"; exit 1; }
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources" "$output/Contents/Helpers"
xcrun clang -fobjc-arc -framework Foundation -framework CoreServices \
  DictionaryBridge.m -o "$output/Contents/Helpers/DictionaryBridge"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  Core.swift Capture.swift Assistant.swift PracticeStudio.swift Knowledge.swift KnowledgeUpdate.swift Workspace.swift Model.swift DictionaryPresentation.swift Views.swift Main.swift SelfTests.swift \
  -framework Cocoa -framework Carbon -framework Vision -framework ScreenCaptureKit \
  -framework AVFoundation -framework CoreServices -framework NaturalLanguage -lsqlite3 \
  -o "$output/Contents/MacOS/Vocab"
cp Info.plist "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$output/Contents/Info.plist"
cp bridge.py books_context.py oxford_entry.py "$output/Contents/Resources/"
cp knowledge/KnowledgeCatalog.json "$output/Contents/Resources/"
# Finder/FileProvider may add attributes to a newly generated bundle in Documents.
# Strip them from this build artifact only before stable signing.
xattr -cr "$output"
zsh "$PWD/sign.sh" "$output"
codesign --verify --deep --strict "$output"
echo "Built and signed: $output"

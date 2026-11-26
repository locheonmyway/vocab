#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
artifact="${1:?Pass a freshly built Vocab.app}"
isolated=0
if [[ "${2:-}" == "--isolated" ]]; then
    root="${3:?Pass a fresh isolated test directory}"
    [[ -d "$root" && "$root" == /tmp/vocab-install.* ]] || { print -u2 "Use mktemp -d /tmp/vocab-install.XXXXXX"; exit 1; }
    isolated=1
    apps="$root/Applications"
    support="$root/Support"
else
    apps="$HOME/Applications"
    support="$HOME/Library/Application Support/Vocab/V2"
fi
target="$apps/Vocab.app"
stamp="$(date +%Y%m%d-%H%M%S)-$(uuidgen)"
rollback="$support/rollback/$stamp"
staged="$apps/.VocabV2-$stamp.app"
[[ -f "$artifact/Contents/MacOS/Vocab" && ! -e "$staged" && ! -e "$rollback" ]]
mkdir -p "$apps" "$rollback"
ditto --norsrc "$artifact" "$staged"
xattr -cr "$staged"
zsh "$PWD/sign.sh" "$staged"
"$staged/Contents/MacOS/Vocab" --distribution-test
old="$rollback/previous-Vocab.app"
if (( isolated )); then
    [[ ! -e "$target" ]] || mv "$target" "$old"
    mv "$staged" "$target"
    codesign --verify --deep --strict "$target"
    print "Verified isolated install: $target"
    exit 0
fi
agent="gui/$(id -u)/com.chloe.vocab"
plist="$HOME/Library/LaunchAgents/com.chloe.vocab.plist"
created=0
if [[ ! -e "$plist" ]]; then
    mkdir -p "${plist:h}"
    python3 - "$plist" "$target" <<'PY'
import plistlib,sys
with open(sys.argv[1], "xb") as f:
    plistlib.dump(dict(Label="com.chloe.vocab", ProgramArguments=[sys.argv[2]+"/Contents/MacOS/Vocab"],RunAtLoad=True,KeepAlive=False),f)
PY
    created=1
fi
running_pids(){ ps -axo pid=,comm= | awk -v target="$target/Contents/MacOS/Vocab" '$2==target {print $1}'; }
launchctl bootout "$agent" 2>/dev/null || true
for pid in $(running_pids); do kill -TERM "$pid" 2>/dev/null || true; done
for attempt in {1..40}; do
    [[ -z "$(running_pids)" ]] && break
    sleep 0.25
done
restore(){
    launchctl bootout "$agent" 2>/dev/null || true
    [[ ! -e "$target" ]] || mv "$target" "$rollback/failed-candidate.app"
    if [[ -e "$old" ]]; then
        mv "$old" "$target"
        launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
    elif (( created )); then
        mv "$plist" "$rollback/failed-launch-agent.plist"
    fi
}
if [[ -n "$(running_pids)" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
    print -u2 "Old Vocab did not exit; original preserved."
    exit 1
fi
if [[ -f "$support/vocab.sqlite3" ]]; then
    if ! python3 - "$support/vocab.sqlite3" "$rollback/vocab.sqlite3" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as source, sqlite3.connect(sys.argv[2]) as dest:
    source.backup(dest)
PY
    then
        launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
        exit 1
    fi
fi
if [[ -f "$support/workspace-state.json" ]] && ! cp "$support/workspace-state.json" "$rollback/"; then
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
    exit 1
fi
if [[ -e "$target" ]]; then
    if ! mv "$target" "$old"; then
        launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
        exit 1
    fi
fi
if ! mv "$staged" "$target" || ! codesign --verify --deep --strict "$target" || ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
    restore
    print -u2 "Candidate failed; prior app restored if present."
    exit 1
fi
for attempt in {1..24}; do
    [[ -n "$(running_pids)" ]] && break
    sleep 0.25
done
if [[ -z "$(running_pids)" ]]; then
    restore
    print -u2 "Candidate did not start; prior app restored if present."
    exit 1
fi
print "Vocab installed: $target"
print "Rollback: $rollback"

#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scratch="$(mktemp -d /tmp/vocab-build.XXXXXX)"
zsh build.sh "$scratch/Vocab.app"
zsh install.sh "$scratch/Vocab.app"

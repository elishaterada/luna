#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./Scripts/build.sh
mkdir -p "$HOME/Applications"
ditto dist/Luna.app "$HOME/Applications/Luna.app"
echo "Installed ~/Applications/Luna.app"
echo "Open Luna and enable the terminal command in the welcome setup or Luna → Settings."

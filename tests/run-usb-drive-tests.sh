#!/bin/bash
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sync"
chmod +x "$T/bin/sync"
export PATH=$T/bin:$PATH
if [ -n "${TOYBOX:-}" ]; then
    for applet in cat chmod cut dirname head ln mkdir mktemp mv readlink rm rmdir sed sleep sort stat tail tr wc; do
        ln -s "$TOYBOX" "$T/bin/$applet"
    done
fi
for shell in sh bash mksh; do
    command -v "$shell" >/dev/null || continue
    timeout 120 "$shell" "$HERE/tests/usb-drive-helper-test.sh" "$T/$shell"
done

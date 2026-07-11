#!/bin/sh
# Materialize upstream binary-only test fixtures without storing them in Git.
# The pub archive is immutable and checksum-pinned.
set -eu

PACKAGE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CACHE=$PACKAGE/.tmp/flterm-0.0.4.tar.gz
URL=https://pub.dev/api/archives/flterm-0.0.4.tar.gz
EXPECTED=d903c7c768f067bcd4e1f00494366522f177ae367fa79b6e9665787ae1463939

hash_file() {
    python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
print(digest)
PY
}

assets_present() {
    test -f "$PACKAGE/test/fixtures/fonts/NotoColorEmoji-Regular.ttf" &&
        test -f "$PACKAGE/test/fixtures/kitty_graphics/test_image.png" &&
        test -f "$PACKAGE/test/rendering/goldens/theme_256_colors.png"
}

mkdir -p "$PACKAGE/.tmp"
if ! test -f "$CACHE" || test "$(hash_file "$CACHE")" != "$EXPECTED"; then
    temporary=$(mktemp "$PACKAGE/.tmp/flterm-0.0.4.XXXXXX")
    trap 'rm -f "$temporary"' EXIT HUP INT TERM
    curl --fail --location --silent --show-error --retry 3 \
        --output "$temporary" "$URL"
    actual=$(hash_file "$temporary")
    if test "$actual" != "$EXPECTED"; then
        echo "flterm archive checksum mismatch: expected $EXPECTED, got $actual" >&2
        exit 1
    fi
    mv "$temporary" "$CACHE"
    trap - EXIT HUP INT TERM
fi

tar -xzf "$CACHE" -C "$PACKAGE" \
    test/fixtures/fonts \
    test/fixtures/kitty_graphics/test_image.png \
    test/rendering/goldens

assets_present || {
    echo "flterm archive did not contain the expected test assets" >&2
    exit 1
}

#!/usr/bin/env bash
#
# Regenerate flterm golden test images inside the same Docker image CI uses
# (`ghcr.io/cirruslabs/flutter:stable`, see .github/workflows/checks.yml).
#
# Why a container: Skia text rasterization on Linux depends on the system
# libfreetype/libpng build, which differs across distros, security updates,
# and macOS hosts. Running `flutter test --update-goldens` directly on
# macOS or vanilla Linux produces slightly different anti-aliasing and
# breaks CI.
#
# Usage:
#   tool/update_goldens.sh             # update all goldens
#   tool/update_goldens.sh path/...    # update a subset
#
# Requires Docker. Run from anywhere inside the repo; the script resolves
# the workspace root from its own location.

set -euo pipefail

readonly IMAGE='ghcr.io/cirruslabs/flutter:stable'

package_root="$(cd "$(dirname "$0")/.." && pwd)"

docker run --rm -i \
  -v "$package_root:/repo" \
  -w /repo \
  -e EXTRA_TEST_ARGS="$*" \
  "$IMAGE" \
  bash <<'SCRIPT'
set -e
flutter pub get
flutter test --update-goldens --tags golden $EXTRA_TEST_ARGS
SCRIPT

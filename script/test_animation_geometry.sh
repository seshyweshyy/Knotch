#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/knotch-animation-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT_DIR/Knotch/components/BottomRoundedRectangle.swift" \
  "$ROOT_DIR/Knotch/components/Notch/NotchShape.swift" \
  "$ROOT_DIR/script/tests/AnimationGeometryTests.swift" \
  -o "$TEST_DIR/AnimationGeometryTests"
"$TEST_DIR/AnimationGeometryTests"

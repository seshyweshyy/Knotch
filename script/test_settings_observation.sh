#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/knotch-settings-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT_DIR/Knotch/components/Settings/SettingsCoordinatorObserver.swift" \
  "$ROOT_DIR/script/tests/SettingsObservationTests.swift" \
  -o "$TEST_DIR/SettingsObservationTests"
"$TEST_DIR/SettingsObservationTests"

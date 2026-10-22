#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--build-only) ;;
  *) echo "usage: $0 [--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac
if [[ "$MODE" != --build-only ]]; then
  pkill -x Knotch >/dev/null 2>&1 || true
fi
xcodebuild -project "$ROOT_DIR/Knotch.xcodeproj" -scheme Knotch \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$ROOT_DIR/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
APP_BUNDLE="$ROOT_DIR/.build/DerivedData/Build/Products/Release/Knotch.app"
case "$MODE" in
  --build-only) exit 0 ;;
  --debug) exec lldb -- "$APP_BUNDLE/Contents/MacOS/Knotch" ;;
  *) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
case "$MODE" in
  --verify) sleep 1; pgrep -x Knotch >/dev/null ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Knotch"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "seshyweshyy.Knotch"' ;;
esac

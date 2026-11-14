#!/bin/sh
# Local IOSurface transfer controls. Pass signed owned Frameworks for the WebGL variant.
set -eu
[ "$#" -le 1 ] || exit 64
frameworks=${1-}
source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d /private/tmp/neantik-xpc-surface.XXXXXX)
printf 'Control directory: %s\n' "$stage"
app="$stage/SurfaceControl.app"
service="$app/Contents/XPCServices/SurfaceControl.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS"
python3 -B - "$app" "$service" "$frameworks" <<'PY'
import plistlib
import sys
from pathlib import Path

app, service = map(Path, sys.argv[1:3])
service_options = {"ServiceType": "Application"}
if sys.argv[3]:
    service_options["RunLoopType"] = "NSRunLoop"
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "app.neantik.qa.SurfaceClient",
    "CFBundleExecutable": "SurfaceClient",
    "CFBundlePackageType": "APPL",
    "LSBackgroundOnly": True,
}))
(service / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "app.neantik.qa.SurfaceControl",
    "CFBundleExecutable": "SurfaceService",
    "CFBundlePackageType": "XPC!",
    "XPCService": service_options,
}))
PY
if [ -n "$frameworks" ]; then
  case "$frameworks" in
    /*) ;;
    *) echo "An absolute owned Frameworks path is required" >&2; exit 64 ;;
  esac
  test -f "$frameworks/WebKit.framework/Versions/A/WebKit"
  xcrun clang -fobjc-arc -Werror -framework Foundation -framework IOSurface -framework Metal \
    "$source_dir/WebGLClient.m" -o "$app/Contents/MacOS/SurfaceClient"
  xcrun clang -fobjc-arc -Werror -framework AppKit -framework Foundation -framework CoreGraphics \
    -framework IOSurface -framework Metal -framework QuartzCore \
    "$source_dir/WebGLService.m" "$frameworks/WebKit.framework/Versions/A/WebKit" \
    -Wl,-rpath,"$frameworks" -o "$service/Contents/MacOS/SurfaceService"
else
  xcrun clang -fobjc-arc -Werror -framework Foundation -framework IOSurface \
    "$source_dir/SurfaceControl.m" -o "$app/Contents/MacOS/SurfaceClient"
  xcrun clang -fobjc-arc -Werror -DNEANTIK_SURFACE_SERVICE -framework Foundation -framework IOSurface \
    "$source_dir/SurfaceControl.m" -o "$service/Contents/MacOS/SurfaceService"
fi
/usr/bin/codesign --force --sign - "$service"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
if "$app/Contents/MacOS/SurfaceClient" > "$stage/transfer.log" 2>&1; then
  cat "$stage/transfer.log"
else
  result=$?
  cat "$stage/transfer.log" >&2
  exit "$result"
fi

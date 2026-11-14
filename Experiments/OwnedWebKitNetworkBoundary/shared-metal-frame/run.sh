#!/bin/sh
set -eu
[ "$#" -le 1 ] || exit 64
source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d /private/tmp/neantik-shared-metal.XXXXXXXX)
printf '%s\n' "$stage"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Metal \
    "$source_dir/FrameTransport.m" -o "$stage/frame-transport"
if [ "$#" -eq 1 ]; then
    frameworks=$1
    case "$frameworks" in
        /*) ;;
        *) echo "An absolute owned Frameworks path is required" >&2; exit 64 ;;
    esac
    test -f "$frameworks/WebKit.framework/Versions/A/WebKit"
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -DNEANTIK_DIRECT_WEBGL \
        -framework Foundation -framework Metal -framework IOSurface -framework AppKit \
        -framework CoreGraphics -framework QuartzCore \
        "$source_dir/FrameTransport.m" "$source_dir/../iosurface-xpc/WebGLService.m" \
        "$frameworks/WebKit.framework/Versions/A/WebKit" -Wl,-rpath,"$frameworks" -o "$stage/webgl-renderer"
    set -- "$stage/webgl-renderer"
fi
result=0
"$stage/frame-transport" "$@" > "$stage/transfer.log" 2>&1 || result=$?
cat "$stage/transfer.log"
exit "$result"

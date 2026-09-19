"""Allow only reviewed, nonprivate GN assignments in public build evidence."""
from pathlib import Path
import re
import sys

BOOL_KEYS = set('''clang_use_chrome_plugins disable_fieldtrial_testing_config
enable_hangout_services_extension enable_mdns enable_remoting enable_reporting
enable_service_discovery enable_widevine exclude_unwind_tables treat_warnings_as_errors
use_official_google_api_keys use_unofficial_version_number v8_drumbrake_bounds_checks
enable_iterator_debugging enable_mse_mpeg2ts_stream_parser enable_rust enable_swiftshader
enable_updater fatal_linker_warnings is_clang is_debug is_official_build proprietary_codecs
use_thin_lto use_sysroot angle_enable_metal'''.split())
INT_KEYS = {'chrome_pgo_phase', 'safe_browsing_mode', 'symbol_level', 'blink_symbol_level'}
STRINGS = {'target_cpu': {'"arm64"'}, 'ffmpeg_branding': {'"Chrome"', '"Chromium"'},
           'google_api_key': {'""'}, 'google_default_client_id': {'""'},
           'google_default_client_secret': {'""'}}


def verify(text):
    count = 0
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        match = re.fullmatch(r'\s*([a-z][a-z0-9_]*)\s*=\s*(.*?)\s*', line)
        if not match:
            raise ValueError(f'Unreviewed public build-argument syntax at line {number}')
        key, value = match.groups()
        allowed = {'true', 'false'} if key in BOOL_KEYS else {'0', '1', '2'} if key in INT_KEYS else STRINGS.get(key, set())
        if value not in allowed:
            # Do not include a potentially credential-bearing value in logs.
            raise ValueError(f'Unreviewed public build argument at line {number}')
        count += 1
    if not count:
        raise ValueError('Empty public build arguments')
    return count


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Usage: verify_public_build_args.py ARGS_GN')
        print('Public build assignments checked:', verify(Path(sys.argv[1]).read_text()))
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

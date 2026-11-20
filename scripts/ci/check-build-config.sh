#!/usr/bin/env bash
# Fails unless Qt WebEngine is built as RelWithDebInfo only: nothing is built as Debug.
#
#   check-build-config.sh configured <build dir>
#       After qt-configure-module, before the build: a wrong setup fails in seconds, not after
#       hours of building.
#   check-build-config.sh built <build dir> <install dir>
#       After cmake --install: checks what was actually built and installed.
#
# Single-config generators (Ninja on Linux and macOS) build CMAKE_BUILD_TYPE, which must be
# RelWithDebInfo. On Windows, Qt's msvc2022_64 is a debug-and-release build, and qt-configure-module
# always uses Ninja Multi-Config and forces Qt's own CMAKE_CONFIGURATION_TYPES (RelWithDebInfo;Debug,
# from QtBuildInternalsExtra.cmake). Debug is then configured but not built: the workflow builds
# and installs with --config RelWithDebInfo, and this script checks that this builds nothing of
# Debug (a ninja dry run), and afterwards that Chromium's GN build has no Debug folder.
set -euo pipefail

expected=RelWithDebInfo
usage="usage: check-build-config.sh configured <build dir> | built <build dir> <install dir>"
mode=${1:?$usage}
build_dir=${2:?$usage}
cache="$build_dir/CMakeCache.txt"

[ -f "$cache" ] || { echo "::error::$cache not found: was the build configured?"; exit 1; }

cache_value() {
    sed -n "s/^$1:[A-Z]*=//p" "$cache" | tr -d '\r'
}

types=$(cache_value CMAKE_CONFIGURATION_TYPES)
build_type=$(cache_value CMAKE_BUILD_TYPE)
echo "CMAKE_CONFIGURATION_TYPES='$types' CMAKE_BUILD_TYPE='$build_type'"

case "$mode" in
configured)
    if [ -n "$types" ]; then
        if ! printf '%s\n' "$types" | tr ';' '\n' | grep -qx "$expected"; then
            echo "::error::Multi-config build without $expected: '$types'."
            exit 1
        fi
        # What `cmake --build . --config RelWithDebInfo` would run, without running it. The Debug
        # parts of Qt WebEngine build in <build>/src/core/Debug and <build>/src/pdf/Debug.
        dry_run=$(cmake --build "$build_dir" --config "$expected" -- -n)
        debug_lines=$(printf '%s\n' "$dry_run" | grep -E '[\\/]Debug([\\/]|$)' || true)
        if [ -n "$debug_lines" ]; then
            echo "$debug_lines" | head -20
            echo "::error::Building --config $expected would also build Debug (lines above)."
            exit 1
        fi
        echo "Multi-config: '$types'. --config $expected builds nothing of Debug ($(printf '%s\n' "$dry_run" | wc -l) build steps checked)."
    elif [ "$build_type" != "$expected" ]; then
        echo "::error::CMAKE_BUILD_TYPE is '$build_type', expected '$expected'."
        exit 1
    fi
    ;;

built)
    install_dir=${3:?$usage}
    failed=0
    # Chromium's GN build folders: <build>/src/{core,pdf}/<config>/<arch>/args.gn.
    shopt -s nullglob
    args=("$build_dir"/src/core/*/*/args.gn "$build_dir"/src/pdf/*/*/args.gn)
    if [ ${#args[@]} -eq 0 ]; then
        echo "::error::No GN args.gn found under $build_dir/src: nothing was built?"
        exit 1
    fi
    for f in "${args[@]}"; do
        echo "$f: $(grep -E '^(is_debug|symbol_level) *=' "$f" | tr -d '\r' | tr '\n' ' ')"
        if [ "$(basename "$(dirname "$(dirname "$f")")")" != "$expected" ] ||
            grep -qE '^is_debug *= *true' "$f"; then
            echo "::error::Not a $expected build: $f"
            failed=1
        fi
    done
    # Debug Qt libraries and plugins on Windows have a d before .dll: Qt6WebEngineCored.dll next
    # to Qt6WebEngineCore.dll.
    debug_libs=""
    while IFS= read -r -d '' f; do
        [ -f "${f%d.dll}.dll" ] && debug_libs+="$f"$'\n'
    done < <(find "$install_dir" -type f -name '*d.dll' -print0)
    if [ -n "$debug_libs" ]; then
        echo "$debug_libs"
        echo "::error::Debug libraries were installed (above)."
        failed=1
    fi
    [ "$failed" -eq 0 ] || exit 1
    ;;

*)
    echo "$usage"
    exit 1
    ;;
esac

echo "OK: only $expected is built (no Debug)."

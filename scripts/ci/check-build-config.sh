#!/usr/bin/env bash
# Fails unless the configured Qt WebEngine build is RelWithDebInfo only: no Debug configuration.
#
#   check-build-config.sh <build dir>
#
# Run after qt-configure-module, before the build: it reads CMakeCache.txt, so a wrong
# configuration fails in seconds, not after hours of building. Single-config generators (Ninja on
# Linux and macOS) use CMAKE_BUILD_TYPE; Ninja Multi-Config (Windows, where Qt's msvc2022_64 is a
# debug-and-release build) uses CMAKE_CONFIGURATION_TYPES and writes one build-<config>.ninja per
# configuration.
set -euo pipefail

expected=RelWithDebInfo
build_dir=${1:?usage: check-build-config.sh <build dir>}
cache="$build_dir/CMakeCache.txt"

[ -f "$cache" ] || { echo "::error::$cache not found: was the build configured?"; exit 1; }

cache_value() {
    sed -n "s/^$1:[A-Z]*=//p" "$cache" | tr -d '\r'
}

types=$(cache_value CMAKE_CONFIGURATION_TYPES)
build_type=$(cache_value CMAKE_BUILD_TYPE)
echo "CMAKE_CONFIGURATION_TYPES='$types' CMAKE_BUILD_TYPE='$build_type'"

if [ -n "$types" ]; then
    if [ "$types" != "$expected" ]; then
        echo "::error::Multi-config build configured for '$types', expected only '$expected'."
        exit 1
    fi
    shopt -s nullglob
    for f in "$build_dir"/build-*.ninja; do
        if [ "$(basename "$f")" != "build-$expected.ninja" ]; then
            echo "::error::Unexpected configuration: $f"
            exit 1
        fi
    done
elif [ "$build_type" != "$expected" ]; then
    echo "::error::CMAKE_BUILD_TYPE is '$build_type', expected '$expected'."
    exit 1
fi

echo "OK: only $expected is built (no Debug)."

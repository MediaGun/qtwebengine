#!/usr/bin/env bash
# Moves the debug symbols of an installed RelWithDebInfo Qt WebEngine out of the install folder, so
# the app ships without them, and keeps them in a separate folder for symbolicating crash reports.
#
#   split-debug-symbols.sh <install dir> <build dir> <symbols dir>
#
# The symbols dir mirrors the install dir's layout:
# - Windows: <name>.pdb next to where <name>.dll/.exe is installed. Taken from the install dir, or
#   from the build dir when cmake --install doesn't install it.
# - Linux: <file>.debug (objcopy --only-keep-debug). The library keeps a .gnu_debuglink to it, so
#   gdb and symbolizers find it when it's put next to the library or under /usr/lib/debug.
# - macOS: <file>.dSYM (dsymutil). The debug info of a Mach-O binary stays in the object files
#   until dsymutil collects it, so this runs while the build dir still exists. strip -S then
#   removes the debug symbol table entries from the binary.
#
# Symbols Qt already split itself (.debug files, .dSYM bundles) are moved as they are.
set -euo pipefail

install_dir=${1:?usage: split-debug-symbols.sh <install dir> <build dir> <symbols dir>}
build_dir=${2:?usage: split-debug-symbols.sh <install dir> <build dir> <symbols dir>}
symbols_dir=${3:?usage: split-debug-symbols.sh <install dir> <build dir> <symbols dir>}

install_dir=$(cd "$install_dir" && pwd)
build_dir=$(cd "$build_dir" && pwd)
mkdir -p "$symbols_dir"
symbols_dir=$(cd "$symbols_dir" && pwd)

count=0

# Moves <file> (a file or a .dSYM folder) under the install dir to the same place under symbols.
move_to_symbols() {
    local rel=${1#"$install_dir"/}
    mkdir -p "$symbols_dir/$(dirname "$rel")"
    rm -rf "${symbols_dir:?}/$rel"
    mv "$1" "$symbols_dir/$rel"
    count=$((count + 1))
}

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
    # PDBs cmake --install put into the install dir.
    while IFS= read -r -d '' pdb; do
        move_to_symbols "$pdb"
    done < <(find "$install_dir" -type f -iname '*.pdb' -print0)

    # PDBs of installed binaries that weren't installed: from the build dir, indexed once (the
    # build dir has hundreds of thousands of files).
    pdb_index=$(mktemp)
    find "$build_dir" -type f -iname '*.pdb' > "$pdb_index"
    while IFS= read -r -d '' bin; do
        rel=${bin#"$install_dir"/}
        name=$(basename "${bin%.*}")
        target="$symbols_dir/$(dirname "$rel")/$name.pdb"
        [ -f "$target" ] && continue
        pdb=$(grep -i -m1 -F "/$name.pdb" "$pdb_index" || true)
        if [ -n "$pdb" ]; then
            mkdir -p "$(dirname "$target")"
            cp "$pdb" "$target"
            count=$((count + 1))
        else
            echo "::warning::No PDB found for $rel"
        fi
    done < <(find "$install_dir" -type f \( -iname '*.dll' -o -iname '*.exe' \) -print0)
    ;;

Linux)
    while IFS= read -r -d '' dbg; do
        move_to_symbols "$dbg"
    done < <(find "$install_dir" -type f -name '*.debug' -print0)

    while IFS= read -r -d '' f; do
        # ELF files only (libraries, QtWebEngineProcess, tools).
        [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
        readelf -S "$f" 2>/dev/null | grep -q '\.debug_info' || continue
        rel=${f#"$install_dir"/}
        dbg="$symbols_dir/$rel.debug"
        mkdir -p "$(dirname "$dbg")"
        objcopy --only-keep-debug "$f" "$dbg"
        objcopy --strip-debug --add-gnu-debuglink="$dbg" "$f"
        count=$((count + 1))
    done < <(find "$install_dir" -type f -print0)
    ;;

Darwin)
    while IFS= read -r -d '' dsym; do
        move_to_symbols "$dsym"
    done < <(find "$install_dir" -type d -name '*.dSYM' -prune -print0)

    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q 'Mach-O' || continue
        rel=${f#"$install_dir"/}
        dsym="$symbols_dir/$rel.dSYM"
        if [ ! -d "$dsym" ]; then
            mkdir -p "$(dirname "$dsym")"
            dsymutil "$f" -o "$dsym"
            count=$((count + 1))
        fi
        strip -S "$f"
    done < <(find "$install_dir" -type f -perm -u+x -print0)
    ;;

*)
    echo "::error::Unsupported system: $(uname -s)"
    exit 1
    ;;
esac

echo "Moved or extracted $count symbol files to $symbols_dir"
du -sh "$install_dir" "$symbols_dir"

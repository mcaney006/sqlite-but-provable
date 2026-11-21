#!/bin/sh
# Check the programs in pass/ compile and the programs in fail/ do not.
# A program in fail/ names, on its first line, text the compiler's error
# must contain, so it cannot fail for an unrelated reason.
#
# Idris only checks files inside its source directory, so each program is
# copied next to links to the library sources and checked there, under its
# own module name so that it cannot replace the compiled Main. The
# library's compiled interface files in build/ are reused.
set -u
IDRIS2="${IDRIS2:-idris2}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
stage="$root/build/typecheck"

rm -rf "$stage"
mkdir -p "$stage"
ln -s "$root/src/IdrisQL" "$stage/IdrisQL"
ln -s "$root/src/IdrisQL.idr" "$stage/IdrisQL.idr"

failed=0
passed=0
cd "$root" || exit 2

check() {
  { echo 'module TypecheckCase'; cat "$1"; } > "$stage/TypecheckCase.idr"
  "$IDRIS2" -p linear --source-dir "$stage" --check "$stage/TypecheckCase.idr" 2>&1
}

for f in "$here"/pass/*.idr; do
  if out="$(check "$f")"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s: expected to compile\n%s\n' "${f#"$root"/}" "$out"
  fi
done

for f in "$here"/fail/*.idr; do
  want="$(sed -n '1s/^-- expect: //p' "$f")"
  if [ -z "$want" ]; then
    failed=$((failed + 1))
    printf 'FAIL %s: no "-- expect:" line\n' "${f#"$root"/}"
    continue
  fi
  if out="$(check "$f")"; then
    failed=$((failed + 1))
    printf 'FAIL %s: compiled, but must be rejected\n' "${f#"$root"/}"
  elif printf '%s' "$out" | tr '\n' ' ' | grep -qF -- "$want"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s: rejected, but not with "%s"\n%s\n' "${f#"$root"/}" "$want" "$out"
  fi
done

rm -rf "$stage"
printf 'typecheck: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

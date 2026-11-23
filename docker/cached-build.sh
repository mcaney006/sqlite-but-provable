#!/bin/sh
# Build the program in the image, reusing the checked modules (TTC files)
# of the previous build on this machine.
#
#   cached-build CACHE-DIRECTORY
#
# Idris 2 0.8.0 decides whether a module is current by comparing file
# times (its -Xcheck-hashes option is disabled). The cache can hold
# modules built from another checkout or a newer commit, where a time
# comparison gives the wrong answer and would link the wrong code in. So
# the content decides here: the cache keeps the SHA-256 of every source
# file it was built from. A file with the same hash is given an old time,
# which makes its cached module current; a file that is new or different
# is given the present time, which makes Idris check it again.
set -eu
cache="$1"
sums=/tmp/sources.sha256
key="$(idris2 --version) $(sha256sum < idrisql.ipkg)"

find src -type f | sort | xargs sha256sum > "$sums"
mkdir -p build

# A different compiler or package description invalidates everything.
if [ -d "$cache/ttc" ] && [ "$(cat "$cache/key" 2>/dev/null)" = "$key" ]; then
  cp -a "$cache/ttc" build/
  find src -type f -exec touch -d '2000-01-01 00:00:00' {} +
  grep -vxFf "$cache/sources.sha256" "$sums" | while read -r _ path; do
    touch "$path"
  done
fi

idris2 --build idrisql.ipkg

rm -rf "$cache/ttc"
cp -a build/ttc "$cache/ttc"
cp "$sums" "$cache/sources.sha256"
printf '%s\n' "$key" > "$cache/key"

#!/bin/sh
# Build Chez Scheme and Idris 2 from source for the pixi tasks. It runs
# once: later runs find the compiler and return at once.
# scripts/pixi-activate.sh says where they go and which versions.
set -eu

tool="${IDRISQL_TOOLCHAIN:?run this through pixi: pixi run toolchain}"
chez_version="${IDRISQL_CHEZ_VERSION:?}"
idris_version="${IDRISQL_IDRIS2_VERSION:?}"

# The marker is written last, so an installation that stopped halfway,
# with the compiler in place and a library missing, is built again.
if [ -e "$tool/.complete" ] && "$tool/bin/idris2" --version 2>/dev/null | grep -q "version $idris_version"; then
  exit 0
fi
rm -f "$tool/.complete"

case "$tool" in
  *" "*) echo "toolchain: '$tool' has a space in it; set IDRISQL_TOOLCHAIN to a path without one" >&2; exit 1 ;;
esac

work="$tool/build"
rm -rf "$work"
mkdir -p "$work"
cd "$work"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

if ! "$tool/bin/scheme" --version >/dev/null 2>&1; then
  echo "toolchain: building Chez Scheme $chez_version into $tool"
  curl -fsSL "https://github.com/cisco/ChezScheme/releases/download/v$chez_version/csv$chez_version.tar.gz" -o chez.tar.gz
  tar xzf chez.tar.gz
  cd "csv$chez_version"
  # Without iconv: the conda environment's iconv.h renames the functions to
  # libiconv's, which Chez's link line on Linux does not include, and Idris
  # uses Chez's own UTF-8 codec.
  ./configure --installprefix="$tool" --threads --disable-x11 --disable-curses --disable-iconv >configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j"$jobs" >build.log 2>&1 || { tail -40 build.log; exit 1; }
  make install >install.log 2>&1 || { tail -40 install.log; exit 1; }
  cd "$work"
fi

echo "toolchain: building Idris 2 $idris_version into $tool"
curl -fsSL "https://github.com/idris-lang/Idris2/archive/refs/tags/v$idris_version.tar.gz" -o idris2.tar.gz
tar xzf idris2.tar.gz
cd "Idris2-$idris_version"
make bootstrap SCHEME=scheme PREFIX="$tool" >bootstrap.log 2>&1 || { tail -40 bootstrap.log; exit 1; }
make install PREFIX="$tool" >install.log 2>&1 || { tail -40 install.log; exit 1; }

cd "$tool"
rm -rf "$work"
"$tool/bin/idris2" --version
touch "$tool/.complete"

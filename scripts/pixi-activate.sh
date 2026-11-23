# Sourced by pixi when it activates the environment.
#
# conda-forge packages neither Chez Scheme nor Idris 2, so
# scripts/pixi-toolchain.sh builds them. They go to a directory in the
# user's cache, not the pixi environment: neither build system accepts an
# installation path with a space in it, a checkout can sit under one, and
# the build takes minutes, so one copy serves every checkout.
#
#   IDRISQL_TOOLCHAIN  where to keep them, to override the default
IDRISQL_CHEZ_VERSION=10.3.0
IDRISQL_IDRIS2_VERSION=0.8.0
IDRISQL_TOOLCHAIN="${IDRISQL_TOOLCHAIN:-${XDG_CACHE_HOME:-$HOME/.cache}/idrisql/chez-$IDRISQL_CHEZ_VERSION-idris2-$IDRISQL_IDRIS2_VERSION}"
PATH="$IDRISQL_TOOLCHAIN/bin:$PATH"
CHEZ="$IDRISQL_TOOLCHAIN/bin/scheme"
export IDRISQL_CHEZ_VERSION IDRISQL_IDRIS2_VERSION IDRISQL_TOOLCHAIN PATH CHEZ

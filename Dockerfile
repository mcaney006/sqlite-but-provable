# syntax=docker/dockerfile:1

# Alpine 3.24 is the first stable release that packages Idris 2 0.8.0.
ARG ALPINE_VERSION=3.24

# Chez Scheme, installed once so that the program is compiled and run by
# the same version.
FROM alpine:${ALPINE_VERSION} AS base
RUN apk add --no-cache chez-scheme

# Idris 2 with the Chez Scheme backend.
FROM base AS toolchain
RUN apk add --no-cache idris2 make \
 && idris2 --version | grep -Eq 'version 0\.(8|9|[1-9][0-9])\.|version [1-9]'
WORKDIR /src

# The program. Only the sources are copied, so a change to documents or
# tests does not invalidate this layer. The cache mount keeps the checked
# modules of the previous build on this machine, so after an edit Idris
# re-checks what changed and not all 37 modules; docker/cached-build.sh
# decides what changed by content. The layer gets its own copy of the
# modules, which the test stage reuses.
FROM toolchain AS build
COPY docker/cached-build.sh /usr/local/bin/cached-build
COPY idrisql.ipkg ./
COPY src ./src
RUN --mount=type=cache,id=idrisql-ttc,target=/cache,sharing=locked cached-build /cache

# The test suites, run on Linux with musl: `docker build --target test .`
FROM build AS test
RUN apk add --no-cache sqlite curl
COPY Makefile ./
COPY scripts ./scripts
COPY tests ./tests
COPY examples ./examples
RUN make check-rules test-unit test-typecheck test-differential test-server demo \
 && ROUNDS=10 make test-crash

# The image that ships: Chez Scheme's runtime, the compiled program, and
# two shell scripts.
FROM base AS runtime
LABEL org.opencontainers.image.title="IdrisQL" \
      org.opencontainers.image.description="An embedded SQL database engine written in Idris 2, with an HTTP server" \
      org.opencontainers.image.source="https://github.com/mcaney006/sqlite-but-provable"
RUN adduser -D -H -u 10001 idrisql \
 && mkdir /data \
 && chown idrisql:idrisql /data
COPY --from=build /src/build/exec/idrisql_app/idrisql.so /src/build/exec/idrisql_app/libidris2_support.so /opt/idrisql/idrisql_app/
COPY docker/idrisql /usr/local/bin/idrisql
COPY docker/entrypoint.sh /usr/local/bin/idrisql-entrypoint
USER idrisql
VOLUME /data
EXPOSE 5480
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s \
  CMD wget -q -Y off -O /dev/null "http://127.0.0.1:${IDRISQL_PORT:-5480}/health" || exit 1
ENTRYPOINT ["idrisql-entrypoint"]
CMD ["serve"]

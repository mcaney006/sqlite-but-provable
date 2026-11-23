IDRIS2 ?= idris2
SRC := $(shell find src -name '*.idr')

.PHONY: all build dev serve test test-unit test-typecheck test-differential test-crash \
        test-server test-container check-rules demo bench microbench docker docker-test clean

all: build

build: build/exec/idrisql

build/exec/idrisql: idrisql.ipkg $(SRC)
	$(IDRIS2) --build idrisql.ipkg

# For the edit-and-run loop: Chez code is generated per module, so a
# rebuild compiles only the modules that changed. The result is
# build-inc/exec/idrisql. Tests, benchmarks and the container image use the
# whole-program build above.
dev:
	IDRIS2_INC_CGS=chez $(IDRIS2) --build-dir build-inc --build idrisql.ipkg

build/exec/idrisql-tests: build/exec/idrisql $(SRC)
	$(IDRIS2) -p linear --source-dir src -o idrisql-tests src/Tests/Main.idr

build/exec/idrisql-microbench: build/exec/idrisql $(SRC)
	$(IDRIS2) -p linear --source-dir src -o idrisql-microbench src/Bench/Micro.idr

# The HTTP server on DB and PORT. SIGPIPE is ignored first: the socket
# library cannot suppress it, and a client that disconnects mid-response
# would otherwise end the server and leave the lock behind.
DB ?= main.idb
PORT ?= 5480

serve: build/exec/idrisql
	trap '' PIPE; ./build/exec/idrisql $(DB) --serve $(PORT) --host 127.0.0.1

# Every suite. test-differential needs sqlite3 on the PATH and test-server
# needs curl.
test: check-rules test-unit test-typecheck test-differential test-crash test-server

check-rules:
	scripts/check-rules.sh

test-unit: build/exec/idrisql-tests
	./build/exec/idrisql-tests

test-typecheck: build/exec/idrisql
	IDRIS2=$(IDRIS2) tests/typecheck/run.sh

test-differential: build/exec/idrisql
	tests/differential/run.sh

test-crash: build/exec/idrisql
	tests/crash/run.sh

test-server: build/exec/idrisql
	tests/server/run.sh

demo: build/exec/idrisql
	rm -rf build/demo.idb
	./build/exec/idrisql build/demo.idb --file examples/demo.sql
	./build/exec/idrisql build/demo.idb --execute "SELECT name, email FROM users ORDER BY id"

bench: build/exec/idrisql
	bench/run.sh

microbench: build/exec/idrisql-microbench
	rm -rf build/microbench.idb
	./build/exec/idrisql-microbench

# The container image, and the same image built only after the test stage
# has passed inside Alpine.
DOCKER ?= docker
IMAGE ?= idrisql:dev

# The image's version label is the version in idrisql.ipkg. Its revision
# label is the commit, marked -dirty when the tree differs from it, and is
# left out where there is no git checkout to ask.
VERSION := $(shell sed -n 's/^version = //p' idrisql.ipkg)
REVISION := $(shell r=$$(git rev-parse HEAD 2>/dev/null) || exit 0; [ -z "$$(git status --porcelain 2>/dev/null)" ] || r=$$r-dirty; echo $$r)

docker:
	$(DOCKER) build --target runtime -t $(IMAGE) \
	  --label org.opencontainers.image.version=$(VERSION) \
	  $(if $(REVISION),--label org.opencontainers.image.revision=$(REVISION)) .

docker-test:
	$(DOCKER) build --target test -t $(IMAGE)-test .

# Runs the image as deploy/aws does and checks start, stop, restart and a
# stale lock.
test-container: docker
	DOCKER=$(DOCKER) REVISION=$(REVISION) tests/container/run.sh $(IMAGE)

clean:
	rm -rf build build-inc

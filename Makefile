IDRIS2 ?= idris2
SRC := $(shell find src -name '*.idr')

.PHONY: all build test test-unit test-typecheck test-differential test-crash \
        check-rules demo bench microbench clean

all: build

build: build/exec/idrisql

build/exec/idrisql: idrisql.ipkg $(SRC)
	$(IDRIS2) --build idrisql.ipkg

build/exec/idrisql-tests: build/exec/idrisql $(SRC)
	$(IDRIS2) -p linear --source-dir src -o idrisql-tests src/Tests/Main.idr

build/exec/idrisql-microbench: build/exec/idrisql $(SRC)
	$(IDRIS2) -p linear --source-dir src -o idrisql-microbench src/Bench/Micro.idr

# Every suite. test-differential needs sqlite3 on the PATH.
test: check-rules test-unit test-typecheck test-differential test-crash

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

demo: build/exec/idrisql
	rm -rf build/demo.idb
	./build/exec/idrisql build/demo.idb --file examples/demo.sql
	./build/exec/idrisql build/demo.idb --execute "SELECT name, email FROM users ORDER BY id"

bench: build/exec/idrisql
	bench/run.sh

microbench: build/exec/idrisql-microbench
	rm -rf build/microbench.idb
	./build/exec/idrisql-microbench

clean:
	rm -rf build

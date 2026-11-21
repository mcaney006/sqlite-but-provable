# File format, version 1

A database is a directory. The constants below are defined in
`src/IdrisQL/Storage/Format.idr`; this document describes them and the code
is the authority. All multi-byte integers are little-endian unless a section
says otherwise.

## Directory layout

| Path | Contents |
|---|---|
| `p/<n div 256>/<n>.pg` | Page `n`, exactly 4096 bytes. 256 pages per subdirectory. |
| `wal` | Write-ahead log |
| `LOCK/` | Present while a process has the database open |
| `spill/<n>.pg` | Pages of the open transaction that were evicted from the buffer pool. Emptied at commit, rollback and open. |
| `tmp/` | Sort runs. Emptied when the query that made them ends and at open. |

Page 0 is the meta page. Page 1 is the root of the catalog tree. Neither is
ever freed.

## Page header

Every page starts with the same 24 bytes.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | Checksum of bytes 4..4095 |
| 4 | 1 | Page type |
| 5 | 1 | Flags, zero in version 1 |
| 6 | 2 | Slot count. On an overflow page: number of data bytes. |
| 8 | 2 | Cell area start: offset of the lowest cell |
| 10 | 2 | Fragmented bytes: space freed inside the cell area |
| 12 | 4 | Right pointer (see below) |
| 16 | 8 | LSN of the log record that last wrote this page |

| Type | Value | Right pointer |
|---|---:|---|
| Meta | 1 | unused |
| Leaf | 2 | next leaf to the right, 0 at the end |
| Internal | 3 | rightmost child |
| Overflow | 4 | next page of the chain, 0 at the end |
| Free | 5 | next page of the free list, 0 at the end |

### Checksum

A 32-bit hash over the 1023 little-endian words that follow the checksum
field, starting from `0x811C9DC5`:

```
h = (rotate_left(h, 5) xor word) * 0x9E3779B1     for each word
checksum = h xor (h >> 15)
```

It detects a torn write. It is not a CRC and gives no guarantee about burst
errors. It does not cover the page's own number, so a whole valid page
written to another page's file passes.

## Meta page (page 0)

| Offset | Size | Field |
|---:|---:|---|
| 24 | 8 | Magic: `IDRISQL` followed by a zero byte |
| 32 | 4 | Format version, 1 |
| 36 | 4 | Page size, 4096 |
| 40 | 8 | Database id, fixed at creation: nanoseconds since the epoch mixed with the process id |
| 48 | 4 | Page count: pages 0..count-1 exist |
| 52 | 4 | First page of the free list, 0 if empty |
| 56 | 4 | Number of pages on the free list |
| 60 | 4 | Catalog root page, 1 |
| 64 | 8 | Id of the last committed transaction |
| 72 | 8 | Schema cookie, incremented by every schema change |
| 80 | 4 | Next object id for tables and indexes |
| 84 | 4 | Unused, zero |
| 88 | 8 | Next LSN |

A build refuses a database whose version is greater than its own, and one
whose page size differs.

## Slotted pages (leaf and internal)

```
+--------+-----------------+ . . . free . . . +--------------------+
| header | slot directory  |                  | cells              |
+--------+-----------------+ . . . . . . . . .+--------------------+
0        24                ^ 24 + 2*slots     ^ cell area start    4096
```

The slot directory holds one 2-byte cell offset per slot, in key order. Cells
are written downwards from the end of the page. Deleting a cell adds its size
to the fragmented-bytes field; the page is compacted when an insert needs the
space.

### Leaf cell

| Size | Field |
|---:|---|
| 2 | Key length `k` |
| 2 | Inline value length `v` |
| 1 | Flags. Bit 0: the value continues in an overflow chain. |
| `k` | Key |
| `v` | Value, or its first `v` bytes |
| 4 | First overflow page (only when bit 0 is set) |
| 4 | Full value length (only when bit 0 is set) |

A key is at most 1000 bytes. When key and value together exceed 1000 bytes
the value moves to an overflow chain and `v` is 0.

### Internal cell

| Size | Field |
|---:|---|
| 2 | Key length `k` |
| 4 | Left child page |
| `k` | Key |

An internal page with keys k0..k(n-1) has children c0..cn. Child ci holds
the keys in [k(i-1), ki). Cell i stores (ki, ci); cn is the right pointer.

### Overflow page

The header's slot-count field holds the number of data bytes, at most 4072.
The data follows the header. The right pointer links to the next page.

## Trees

Every table and index is a B+ tree with byte-string keys compared bytewise.
Leaves are linked left to right. A tree's root page id never changes: when
the root splits, its contents move to a new page and the root becomes an
internal page above it.

A node that falls below a quarter of its usable space merges with a sibling
or borrows cells from one. A non-root leaf can stay empty when neither is
possible; the integrity check counts such leaves and does not treat them as
damage.

### Table tree

Key: the rowid as 8 bytes big-endian with the sign bit flipped, so that
bytewise order is numeric order. Value: the row.

### Index tree

Key: the indexed columns in the key encoding below, followed by the rowid in
the table-key encoding. Value: empty. The rowid makes every key distinct, so
a non-unique index needs no duplicate handling. A unique index is enforced by
looking for another key with the same column prefix before inserting; a
prefix that contains NULL is exempt.

### Catalog tree (root page 1)

Key: `t:<lower-cased table name>` or `i:<lower-cased index name>` as UTF-8.

Table entry value: byte 1 (kind), byte 1 (entry version), u32 object id,
name, u32 root page, column list (name, type code, NOT NULL flag, optional
default expression as SQL text), optional rowid column position, CHECK
expressions as SQL text, foreign keys (columns, referenced table, referenced
columns), i64 row estimate (-1 until ANALYZE runs).

Index entry value: byte 2 (kind), byte 1 (entry version), u32 object id,
name, table name, u32 root page, column positions, unique flag,
constraint-owned flag, i64 distinct-key estimate.

Strings are a u32 byte length and UTF-8 bytes. Lists are a u16 count and the
elements.

## Row format

u16 column count, then for each column a tag byte and a payload:

| Tag | Type | Payload |
|---:|---|---|
| 0 | NULL | none |
| 1 | INTEGER | 8 bytes |
| 2 | REAL | 8 bytes, IEEE 754 double |
| 3 | TEXT | u32 length, UTF-8 |
| 4 | BLOB | u32 length, bytes |
| 5 | BOOLEAN false | none |
| 6 | BOOLEAN true | none |

Decoding is driven by the table's declared column types. A tag that does not
match the declared type is reported as corruption.

## Key encoding

Comparing two encoded keys bytewise gives the same result as comparing the
values column by column with NULL first.

| Tag | Type | Payload |
|---:|---|---|
| 0x05 | NULL | none |
| 0x10 | BOOLEAN | one byte, 0 or 1 |
| 0x20 | INTEGER | 8 bytes big-endian, sign bit flipped |
| 0x30 | REAL | 8 bytes big-endian; sign bit flipped for values >= 0, all bits flipped for negative values; -0.0 is stored as 0.0 |
| 0x40 | TEXT | UTF-8 with each 0x00 written as 0x00 0xFF, ended by 0x00 0x00 |
| 0x50 | BLOB | same escaping as TEXT |

## Write-ahead log (`wal`)

Header, 32 bytes:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Magic: `IDQLWAL` followed by a zero byte |
| 8 | 4 | Format version, 1 |
| 12 | 4 | Page size, 4096 |
| 16 | 8 | Database id; must equal the meta page's |
| 24 | 8 | Salt; changes every time the log is emptied |

Record:

| Size | Field |
|---:|---|
| 4 | Type: 1 page image, 2 commit |
| 4 | Page id (0 in a commit record) |
| 8 | LSN |
| 8 | Transaction id |
| 4 | Payload length: 4096 for a page image, 0 for a commit |
| payload | The page, with its own checksum and this record's LSN |
| 4 | Checksum of the 28 header bytes and the payload, seeded with `0x811C9DC5 xor salt` |

A reader stops at the first record that is incomplete or fails its checksum.
Everything before that point is valid; everything from it on is ignored.
`docs/TRANSACTIONS.md` describes how the log is used.

## Limits

| Limit | Value |
|---|---|
| Page size | 4096 bytes |
| Key | 1000 bytes. An index entry whose encoded columns and rowid exceed this is refused. |
| Row | Bounded by memory: a row is read whole. A 20,000-byte TEXT value is exercised in `src/Tests/Sql.idr`. |
| Pages | 2^32 - 1 (page ids are 32-bit; 0 means none) |
| Rowid | -2^63 .. 2^63 - 1 |
| Tree depth | 64 levels; deeper is reported as corruption |

## Compatibility rule

A change to any layout in this document requires a new format version. A
build opens versions up to its own and refuses newer ones. There is no
upgrade tool, because version 1 is the only version.

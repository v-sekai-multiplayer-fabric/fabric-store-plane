# fabric-store-plane

The store plane is a native process. SQLite runs inside it with a custom VFS, and that VFS
reads and writes pages in FoundationDB. The BEAM reaches the plane over Eclipse iceoryx2.
The plane reaches FoundationDB with the native client, `libfdb_c`.

```
BEAM control plane
  |  iceoryx2, zero copy, same machine
store plane (native)
  |  SQLite + custom VFS
  |  page reads and commits
  |  libfdb_c, over the network
FoundationDB
```

There is no local file, so an actor's database moves between machines with no copy and no
restore step. That is the property the whole design rests on, and `prove_handoff.c` is it
on its own:

```
=== process A: write ===
wrote 3 rows to zone-atlantis.db, no local file
=== process B: read, no local file ===
ls: cannot access 'zone-atlantis.db': No such file or directory
  owner = machine-a
  seq = 200
  zone = atlantis
read 3 rows from zone-atlantis.db in a new process, nothing was copied
```

`thirdparty/harness` is
[`fabric-harness`](https://github.com/v-sekai-multiplayer-fabric/fabric-harness), pulled
in as a subtree. It carries the iceoryx2 C ABI and the shared limits, and this plane links
it rather than linking iceoryx2.

## State

The VFS is built. A commit is one FoundationDB transaction, and reads, writes, compaction,
and the fence run against a live cluster.

The plane itself is not built. The bus works and the loop that sits on it does not, so
nothing calls this VFS except the programs beside it.

Everything proposed and everything unbuilt is in the
[issues](https://github.com/v-sekai-multiplayer-fabric/fabric-store-plane/issues):
read-ahead, pins, the index bound on a very large commit, many writers committing at once,
the plane process itself, and deleting the Elixir prototype it replaces.

## Where the design is written down

Every rule sits beside the code it governs, so this file does not repeat it.

| what | where |
| --- | --- |
| the key layout, and why a read touches two rows | `fdb_vfs.c`, the file comment |
| what a caller must set, and why | `fdb_vfs.c`, the file comment |
| the commit protocol, and the staging path a large commit takes | `flush` in `fdb_vfs.c` |
| the compaction rules and the ratio that triggers them | the compaction section of `fdb_vfs.c` |
| the fence, and what two writers did without one | `prove_concurrency.c`, and `check_fence` |
| why a crash point beats a delay | `prove_crash.c` |
| what the crash search covers, and what it found | `witness/CrashSearch.lean` |
| the measured numbers, and what they mean for the design | `bench_vfs.c` |
| the retry loop every transaction runs in | `run_txn` in `fdb_vfs.c` |

The proofs are weft's. `docs/spec/Store.lean` holds the layout and the compaction rules,
`docs/spec/Prefetch.lean` holds read-ahead, and `docs/logbook/store_plane.md` holds every
measured number with the cluster and the settings that produced it.

## Build

The build needs the FoundationDB client and SQLite headers.

```
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

The `Containerfile` carries both, and is the reproducible path:

```
podman build -t fabric-store-plane .
```

## Run

Every program takes the cluster file from `WEFT_FDB_CLUSTER_FILE` and needs a live
FoundationDB.

```
export WEFT_FDB_CLUSTER_FILE=/etc/foundationdb/fdb.cluster

./build/prove_handoff write zone-atlantis.db   # then read, in a new process
./build/prove_crash crash.db 400 at 7          # crash before the 7th commit
./build/prove_concurrency one.db 1 300         # two writers, one database
./build/prove_big_commit big.db 2000 8192      # a commit past one transaction
./build/integrity zone-atlantis.db             # SQLite's own audit
./build/bench_vfs 1000                         # against a local file
```

`soak.sh` runs the load, kill, and crash rounds in turn, and reports which round failed
and what it printed rather than a count. Point `BIN` at the build directory:

```
BIN=build ./soak.sh 3600
```

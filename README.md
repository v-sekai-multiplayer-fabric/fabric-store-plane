# fabric-store-plane

An actor's database with no local file.

SQLite runs inside a native process with a custom VFS, and that VFS reads and writes pages
in FoundationDB. The BEAM reaches the plane over Eclipse iceoryx2, and the plane reaches
FoundationDB with the native client, `libfdb_c`.

```
BEAM control plane
  |  iceoryx2, zero copy, same machine
store plane (native)
  |  SQLite + custom VFS
  |  page reads and commits
  |  libfdb_c, over the network
FoundationDB
```

Because there is no file, a handoff copies nothing. One process writes, and another
machine opens the same database and reads pages, with no restore step and no transfer:

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

A large actor moves as fast as a small one, and an actor is no longer limited by memory.
That is what the plane is for.

## State

The VFS is built. A commit is one FoundationDB transaction, and reads, writes, compaction,
and the fence run against a live cluster.

The plane itself is not built. The bus works and the loop that sits on it does not, so
nothing calls this VFS except the programs beside it. What is unbuilt and what is proposed
are in the [issues](https://github.com/v-sekai-multiplayer-fabric/fabric-store-plane/issues).

## Build and run

The build needs the FoundationDB client and SQLite headers. The `Containerfile` carries
both, and is the reproducible path.

```
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Every program needs a live FoundationDB and takes the cluster file from the environment.
Each one prints its own usage. Start with the handoff, which is the output above:

```
export WEFT_FDB_CLUSTER_FILE=/etc/foundationdb/fdb.cluster
./build/prove_handoff write zone-atlantis.db
./build/prove_handoff read zone-atlantis.db
```

`BIN=build ./soak.sh 3600` runs the load, kill, and crash rounds in turn.

## Reading the code

Start at the file comment in `fdb_vfs.c`. It holds the key layout, what a caller must set,
and how a commit is made atomic; the rest of the design sits beside the code it governs,
and each program says in its own header what it proves and why that question is worth
asking.

The proofs and the numbers are weft's, in `docs/spec/` and `docs/logbook/`.
`thirdparty/harness` is
[`fabric-harness`](https://github.com/v-sekai-multiplayer-fabric/fabric-harness) as a
subtree, and carries the iceoryx2 C ABI and the shared limits.

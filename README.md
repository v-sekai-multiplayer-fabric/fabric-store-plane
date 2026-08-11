# fabric-store-plane

An actor's database with no local file. SQLite runs in a native process with a custom VFS
whose pages live in FoundationDB, so a handoff copies nothing: another machine opens the
same database and reads pages. A large actor moves as fast as a small one.

The VFS is built and runs against a live cluster. The plane process is not, so nothing
calls the VFS but the programs beside it. Unbuilt and proposed work is in the
[issues](https://github.com/v-sekai-multiplayer-fabric/fabric-store-plane/issues).

The build needs the FoundationDB client and SQLite headers, which the `Containerfile`
carries. Every program needs a live FoundationDB and prints its own usage.

```
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
export WEFT_FDB_CLUSTER_FILE=/etc/foundationdb/fdb.cluster
./build/prove_handoff write zone.db && ./build/prove_handoff read zone.db
```

Start at the file comment in `fdb_vfs.c`. The design sits beside the code it governs.

# fabric-store-plane

SQLite runs in a native process with a custom VFS with no local file. The pages live in FoundationDB, so a handoff copies nothing: another machine opens the
same database and reads pages.

# fabric-store

SQLite runs in a native process with a custom VFS with no local file. The pages live in FoundationDB, so a handoff copies nothing: another machine opens the
same database and reads pages.

## Licence

Licensed under either of

* Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
* MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.

`SPDX-License-Identifier: Apache-2.0 OR MIT`

### Scope

These terms cover this repository's own code. They do not relicense vendored code under
`thirdparty/`, which keeps the terms it arrived with. `thirdparty/harness` is a subtree of the
harness repository and is governed there. It vendors code in turn, and
`thirdparty/harness/thirdparty/generate_stubs/LICENSE.chromium` is the licence that applies to
that part.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion
in this work by you shall be dual licensed as above, without any additional terms or
conditions.

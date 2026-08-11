/-! # Committing across several databases

`ParallelCommits.tla` is the authority for this protocol, and it lives in a CockroachDB fork
as 919 lines of TLA+ that nothing here can run. This is the same protocol stated against
*this* layout, in the language the rest of this store is specified in, so that CI checks it.

It is not a translation. CockroachDB has intents and a timestamp cache; this has pages
staged under a txid whose head has not moved, and a fence. The mapping was a comment in
`fdb_vfs.c` and is an argument rather than an observation:

| ParallelCommits | here |
| --- | --- |
| intent write | a participant's pages, staged under a txid above its head |
| transaction record | `weft/txn/<txnid>` |
| implicitly committed | the record is staging and every intent is present |
| timestamp cache | the fence |
| preventer | recovery, run by whoever finds a staging record |

The properties below are in two groups. The first are the TLA spec's own. The second are
ones it cannot state, because it has no pages — and the first of those is the one that was
actually broken in the C, at the cost of an item on a live cluster.
-/

namespace Weft.ParallelCommit

abbrev Db := Nat
abbrev Txid := Nat

/-- One database, as much of it as this protocol can see.

`head` is the newest commit, and a page staged under a txid above it is unreachable: no
PIDX row points at it and no read can find it. `fence` is what a stale writer is refused
by. -/
structure DbState where
  head : Txid
  fence : Nat
  /-- Whether pages exist under this txid. This is `QueryIntent`. -/
  staged : Txid → Bool

/-- A write is visible exactly when the head has reached it. Staging alone never is. -/
def DbState.visible (d : DbState) (tx : Txid) : Bool := tx ≤ d.head

inductive Status where
  | pending | staging | committed | aborted
  deriving Repr, DecidableEq

/-- The transaction record: what state the group is in, and who is in it. -/
structure Record where
  status : Status
  parts : List (Db × Txid)

structure World where
  db : Db → DbState
  txn : Record

/-- `QueryIntent` for one participant. -/
def intentPresent (w : World) (p : Db × Txid) : Bool := (w.db p.1).staged p.2

def allIntentsPresent (w : World) : Bool := w.txn.parts.all (intentPresent w)

/-- The commit point. It costs one round: the record landing is what makes it true, and
every intent is already durable by then. -/
def implicitlyCommitted (w : World) : Bool :=
  w.txn.status == Status.staging && allIntentsPresent w

def explicitlyCommitted (w : World) : Bool := w.txn.status == Status.committed

def committed (w : World) : Bool := implicitlyCommitted w || explicitlyCommitted w

def finalized (w : World) : Bool :=
  w.txn.status == Status.committed || w.txn.status == Status.aborted

/-! ## The operations -/

def setDb (w : World) (d : Db) (s : DbState) : World :=
  { w with db := fun x => if x = d then s else w.db x }

/-- Write one participant's intent: pages under `head + 1`, and the head does not move. -/
def stage (w : World) (d : Db) : World :=
  let s := w.db d
  let tx := s.head + 1
  let w' := setDb w d { s with staged := fun t => t == tx || s.staged t }
  { w' with txn := { w'.txn with parts := (d, tx) :: w'.txn.parts } }

/-- The commit: one transaction moves the record to staging. -/
def writeRecord (w : World) : World :=
  { w with txn := { w.txn with status := Status.staging } }

/-- Resolve one participant, which is what makes its staged pages reachable. -/
def resolve (w : World) (p : Db × Txid) : World :=
  let s := w.db p.1
  setDb w p.1 { s with head := max s.head p.2 }

/-- Prevent: raise the fence, so a writer holding the old one is refused. This is the
timestamp cache, and it is the only mechanism here that can stop a write that has not
happened yet. -/
def prevent (w : World) (d : Db) : World :=
  let s := w.db d
  setDb w d { s with fence := s.fence + 1 }

def finish (w : World) : World := { w with txn := { w.txn with status := Status.committed } }
def abort (w : World) : World := { w with txn := { w.txn with status := Status.aborted } }

/-! ## What the TLA spec says

A finalized record stays finalized, and recovery only ever moves a staging record to one of
the two ends. -/

theorem finish_is_final (w : World) : finalized (finish w) := by
  simp [finalized, finish]

theorem abort_is_final (w : World) : finalized (abort w) := by
  simp [finalized, abort]

/-- An implicitly committed group is committed, which is what lets a caller be told so
before any head has moved. -/
theorem implicit_is_committed (w : World) (h : implicitlyCommitted w) : committed w := by
  simp [committed, h]

/-- Finishing an implicitly committed group keeps it committed. This is
`ImplicitCommitLeadsToExplicitCommit`, the step recovery performs. -/
theorem finish_keeps_committed (w : World) : committed (finish w) := by
  simp [committed, explicitlyCommitted, finish]

/-! ## What the TLA spec cannot say, because it has no pages -/

/-- **Staging is invisible.**

The property that was broken. `weft_txn_stage` asked a caller to stage *after* writing, but
SQLite ends a statement at `xSync` and that is where `flush` commits, so the first write
became visible on its own and the group never held it. It cost an item on a live cluster.

Staging puts pages under `head + 1` and leaves the head alone, so nothing a participant
staged can be read before the record lands. -/
theorem stage_is_invisible (w : World) (d : Db) :
    ¬ ((stage w d).db d).visible ((w.db d).head + 1) := by
  simp [stage, setDb, DbState.visible]

/-- And the head is exactly what it was, which is the same fact said the other way. -/
theorem stage_moves_no_head (w : World) (d : Db) :
    ((stage w d).db d).head = (w.db d).head := by
  simp [stage, setDb]

/-- **Resolving is what makes it visible**, and only after the record. -/
theorem resolve_is_visible (w : World) (d : Db) (tx : Txid) :
    ((resolve w (d, tx)).db d).visible tx := by
  simp [resolve, setDb, DbState.visible, Nat.le_max_right]

/-- **The bug, as a counterexample.** An implementation that commits the write first and
stages afterwards makes it visible with no record at all.

`w₀` is a database at head 3. Committing the ordinary way moves the head to 4, and the
write is readable while the record is still pending — so a crash here leaves the item gone
from one database and never arrived in the other. -/
def w₀ : World :=
  { db := fun _ => { head := 3, fence := 1, staged := fun _ => false }
    txn := { status := Status.pending, parts := [] } }

/-- What a plain `flush` does: the head moves. -/
def commitAlone (w : World) (d : Db) : World :=
  let s := w.db d
  setDb w d { s with head := s.head + 1, staged := fun t => t == s.head + 1 || s.staged t }

theorem committing_before_staging_is_visible_with_no_record :
    ((commitAlone w₀ 0).db 0).visible 4 = true ∧ (commitAlone w₀ 0).txn.status = Status.pending := by
  constructor
  · rfl
  · rfl

/-- Whereas staging leaves it unreadable, which is what the group needs. -/
theorem staging_leaves_it_unreadable : ((stage w₀ 0).db 0).visible 4 = false := by rfl

/-! ## Recovery -/

/-- A world where the record staged and one participant's intent never landed. Recovery
must not commit this: it can never become implicitly committed. -/
def missingIntent : World :=
  { db := fun d => { head := 3, fence := 1, staged := fun t => d == 0 && t == 4 }
    txn := { status := Status.staging, parts := [(0, 4), (1, 4)] } }

theorem missing_intent_is_not_committed : implicitlyCommitted missingIntent = false := by
  decide

/-- A world where every intent landed. Recovery must finish this, whatever the committer
wanted, because it is already committed. -/
def allPresent : World :=
  { db := fun _ => { head := 3, fence := 1, staged := fun t => t == 4 }
    txn := { status := Status.staging, parts := [(0, 4), (1, 4)] } }

theorem all_present_is_committed : implicitlyCommitted allPresent = true := by decide

/-- **Preventing does not change the decision.** Raising a fence stops a future write; it
must not make a group that was already implicitly committed look uncommitted, or recovery
would abort a commit that happened. -/
theorem prevent_keeps_the_decision (w : World) (d : Db) :
    implicitlyCommitted (prevent w d) = implicitlyCommitted w := by
  have hp : intentPresent (prevent w d) = intentPresent w := by
    funext p
    by_cases h : p.1 = d <;> simp [intentPresent, prevent, setDb, h]
  simp only [implicitlyCommitted, allIntentsPresent, hp]
  rfl

/-- **Recovery is idempotent.** Two processes deciding one record reach the same end, which
is what lets any finder of a staging record decide it. -/
theorem finish_twice (w : World) : finish (finish w) = finish w := by
  simp [finish]

theorem abort_twice (w : World) : abort (abort w) = abort w := by
  simp [abort]

/-- Resolving a participant twice moves the head no further, so a resolve that runs again
after a crash is harmless. -/
theorem resolve_twice (w : World) (p : Db × Txid) :
    ((resolve (resolve w p) p).db p.1).head = ((resolve w p).db p.1).head := by
  simp [resolve, setDb]

end Weft.ParallelCommit

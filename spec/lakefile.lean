import Lake
open Lake DSL

package «weft-storeplane-spec» where
  -- Pure Lean, and no dependencies. A spec that needs a network to check is a spec
  -- nobody checks.

@[default_target] lean_lib «ReadAhead» where
  roots := #[`ReadAhead]

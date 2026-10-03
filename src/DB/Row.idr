||| `Row`<->record mapping interfaces. Declared here, hand-written, and
||| kept separate from `Derive.PGRow` (which derives implementations of
||| these) for the same reason `Prelude.Show` and `Derive.Show`'s own
||| `Show` alias function live in different modules: a module can't
||| declare an interface and a same-named top-level function together.
module DB.Row

import Data.PGValue
import DB.Table

%default total

public export
interface FromRow a where
  constructor MkFromRow
  fromRow : Row -> Either String a

public export
interface ToRow a where
  constructor MkToRow
  toRow : a -> List (Maybe String)

||| A pure, compile-time-only link from a pk-less "new" record type
||| (`ins`) to the table it inserts into (`a`) - no methods. Idris2 has
||| no functional-dependency syntax (confirmed directly - `| ins -> a`
||| is a parse error), so this can't make `insert` infer `a` from `ins`
||| automatically; callers still write `insert {a=Todo} db newTodo`, same
||| as `findById`/`deleteById` already require. What this DOES still buy:
||| a real compile-time check that `ins` was actually declared as this
||| table's insert-shape (`Insertable NewTodo Todo where`) - passing some
||| unrelated `ToRow`-having type at `{a=Todo}` won't typecheck.
public export
interface Table a => Insertable ins a where
  constructor MkInsertable
  ||| Unused - present only so Idris2's elaborator can determine `ins`
  ||| (same "Unsolved holes" quirk noted on `Table.tableWitness`, since
  ||| `Insertable` otherwise has no methods mentioning `ins` at all). A
  ||| real value is still required in every implementation (`id`).
  insertWitness : ins -> ins

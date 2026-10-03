||| Static, per-type table metadata plus the four fixed SQL strings
||| `DB.Crud`'s generic CRUD helpers run - declared here, hand-
||| written, and kept separate from `Derive.PGTable` (which derives
||| implementations of it) for the same reason `Prelude.Show` and
||| `Derive.Show`'s own `Show` alias function live in different modules:
||| a module can't declare an interface and a same-named top-level
||| function together.
module DB.Table

public export
interface Table a where
  constructor MkTable
  ||| Unused - present only so Idris2's elaborator can determine this
  ||| interface's type parameter. `Table` is otherwise pure static
  ||| metadata with no real per-value use for `a`, but confirmed
  ||| empirically: an interface whose methods never mention `a` anywhere
  ||| fails to elaborate at all ("Unsolved holes"), a genuine Idris2
  ||| 0.8.0 elaborator quirk, not a design choice - a real value is still
  ||| required in every implementation regardless (`Derive.PGTable`
  ||| always supplies `id`).
  tableWitness  : a -> a
  tableName     : String
  columns       : List String
  pkColumn      : String
  pkIndex       : Nat
  insertSql     : String
  selectByIdSql : String
  updateSql     : String
  deleteByIdSql : String
  ||| `CREATE TABLE IF NOT EXISTS <table> (...)`, generated from each
  ||| field's `DB.ColumnType` instance (`NOT NULL` unless the
  ||| field's Idris type is `Maybe _`; the pk column uses
  ||| `SERIAL`/`BIGSERIAL` when its type has one). Unlike the SQL
  ||| strings above, this is a genuine runtime-dispatched value, not a
  ||| compile-time literal - see `DB.ColumnType`'s own doc comment
  ||| for why that's fine specifically for DDL.
  createTableSql : String

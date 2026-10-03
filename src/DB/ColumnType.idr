||| Maps an Idris type to the Postgres column type used when deriving
||| `Table`'s `createTableSql` (`DB.Derive.ActiveRecord`).
|||
||| Deliberately a separate typeclass from `DB.Field`'s
||| `FromField`/`ToField`, not reusing them: a type can have a
||| well-defined wire encoding without one canonical SQL column type
||| (`Integer` decodes from `int2`/`int4`/`int8`/`numeric` text
||| indifferently, but a *declared* `Integer` column still has to pick
||| one concrete Postgres type), and the reverse can hold too.
|||
||| Unlike `Table`'s other generated SQL strings (`insertSql`/etc, which
||| are compile-time literals - justified there by `DB.stmtCache`'s
||| exact-text keying, since those run through the extended query
||| protocol on every call), `createTableSql` is a genuine
||| runtime-dispatched value: DDL normally runs once at startup, so the
||| prepared-statement-cache argument doesn't really apply, and a real
||| typeclass here (matching `FromField`/`ToField`'s own precedent)
||| means a consumer can add a `PGColumnType` instance for their own
||| type - an enum stored as `TEXT`, say - without touching this
||| library's derive code at all.
module DB.ColumnType

%default total

public export
interface PGColumnType a where
  ||| The SQL type for a plain (non-nullable, non-pk) column of this
  ||| type.
  pgColumnType : String

  ||| The SQL type for a column of this type used as an
  ||| auto-incrementing primary key (`"SERIAL"`/`"BIGSERIAL"`) -
  ||| Postgres assigns the value, matching `deriveInsertable`'s own
  ||| assumption that the caller never supplies one for the pk.
  ||| `Nothing` (the default) means this type has no sensible
  ||| auto-increment form - `Table`'s derivation falls back to
  ||| `pgColumnType` plus a plain `PRIMARY KEY` instead, for a
  ||| caller-assigned key (a `String` UUID/slug, say).
  pgAutoIncrementType : Maybe String
  pgAutoIncrementType = Nothing

  ||| Whether this column should allow `NULL`. Always `False` for a
  ||| plain type; only the blanket `Maybe` instance below sets it -
  ||| not meant to be overridden directly by other instances.
  pgNullable : Bool
  pgNullable = False

public export
PGColumnType a => PGColumnType (Maybe a) where
  pgColumnType = pgColumnType {a}
  -- A nullable field is never a sensible auto-increment pk - falls
  -- back to the non-nullable case's `Nothing` default.
  pgNullable = True

public export
PGColumnType String where
  pgColumnType = "TEXT"

public export
PGColumnType Bool where
  pgColumnType = "BOOLEAN"

public export
PGColumnType Int where
  pgColumnType = "INTEGER"
  pgAutoIncrementType = Just "SERIAL"

||| `BIGINT`, not `INTEGER` - matches `Data.PGValue.getInteger`'s own
||| doc comment ("arbitrary-precision, for numeric/bigint values that
||| don't fit Int"), the closest fixed-width Postgres type this
||| library already pairs `Integer` with elsewhere.
public export
PGColumnType Integer where
  pgColumnType = "BIGINT"
  pgAutoIncrementType = Just "BIGSERIAL"

public export
PGColumnType Double where
  pgColumnType = "DOUBLE PRECISION"

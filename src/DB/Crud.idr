||| Generic CRUD helpers built on top of `queryRows`/`Table`/`FromRow`/
||| `ToRow`/`Insertable`. These are ordinary polymorphic functions, NOT
||| derived per type - only the type-level description (table name,
||| columns, SQL text) is generated; the actual query execution logic is
||| written once here and reused via typeclass dispatch.
|||
||| `a` never appears in `findById`/`deleteById`'s own arguments, so a
||| call site must supply it explicitly: `findById {a=Todo} db tid`. The
||| same is true of `insert` - see `Derive.PGRow.Insertable`'s doc comment
||| for why (Idris2 has no functional-dependency syntax to infer it from
||| the insert-shape argument alone): `insert {a=Todo} db newTodo`.
|||
||| A typed `SELECT` query builder now exists (`DB.Query`'s
||| `selectQuery`/`Condition`/`Query`, with per-table column references
||| from `DB.Derive.ActiveRecord.deriveColumns`) for filtering/ordering/
||| paging beyond "by id" - `insert`/`update`/`deleteById` here stay
||| by-pk only. Still explicitly out of scope: no relations/joins, no
||| migrations, no partial-update/PATCH (`update` always replaces every
||| non-pk column - same as `updateSql`'s own shape); no dedicated
||| `PGError` case for constraint violations - callers who need to
||| distinguish e.g. a unique-violation inspect `SqlError`'s `code`/
||| `constraintName` (`Data.PGTypes`) themselves, same as today; no bulk
||| `updateWhere`/`deleteWhere` by an arbitrary condition (as opposed to
||| by pk) - would reuse `DB.Query.compileCondition` cheaply as a
||| later addition, not built yet.
module DB.Crud

import Idris2_pg
import Data.PGTypes
import Data.PGValue
import DB.Field
import DB.Row
import DB.Table

%default total

atIndex : Nat -> List a -> Maybe a
atIndex Z     (x :: _)  = Just x
atIndex (S n) (_ :: xs) = atIndex n xs
atIndex _     []        = Nothing

dropIndex : Nat -> List a -> List a
dropIndex Z     (_ :: xs) = xs
dropIndex (S n) (x :: xs) = x :: dropIndex n xs
dropIndex _     []        = []

-- `toRow rec` is in the record's own declaration order (pk included,
-- wherever it falls); `updateSql` expects non-pk columns first, pk last
-- - this moves it there.
updateParams : (Table a, ToRow a) => a -> List (Maybe String)
updateParams {a} rec =
  let vals := toRow rec
      pk   := pkIndex {a}
   in dropIndex pk vals ++ maybe [] (\v => [v]) (atIndex pk vals)

||| Decodes the first row of a hand-written SQL result (`Nothing` for
||| `[]`, not an error - "no matching row" is client-caused, not a
||| decode failure), the same "single optional row" shape `findById`/
||| `update` use internally. Exported as a reusable extension point for
||| a caller's own hand-written SQL outside the fixed CRUD shape (e.g. a
||| partial update `DB.Crud` itself has no primitive for) that still
||| wants this exact decode behavior instead of duplicating it.
export
decodeFirst : FromRow a => List Row -> Either PGError (Maybe a)
decodeFirst []       = Right Nothing
decodeFirst (r :: _) = case fromRow r of
  Right v  => Right (Just v)
  Left err => Left (ProtocolError ("could not decode a row: " ++ err))

||| Inserts `rec` (a table's pk-less "new" record - see `Insertable`)
||| and returns the full row Postgres created, `RETURNING`-decoded via
||| `FromRow`.
export
insert : (Insertable ins a, ToRow ins, FromRow a) => DB -> ins -> IO (Either PGError a)
insert {a} db rec = do
  Right rows <- queryRows db (insertSql {a}) (toRow rec)
    | Left err => pure (Left err)
  case rows of
    []       => pure (Left (ProtocolError "insert did not return a row"))
    (r :: _) => pure $ case fromRow {a} r of
      Right v  => Right v
      Left err => Left (ProtocolError ("could not decode inserted row: " ++ err))

||| `Right Nothing` (not an error) when no row has that id - matches
||| this codebase's existing "empty result means 404" idiom.
export
findById : (Table a, FromRow a, ToField pk) => DB -> pk -> IO (Either PGError (Maybe a))
findById {a} db pkVal = do
  Right rows <- queryRows db (selectByIdSql {a}) [toField pkVal]
    | Left err => pure (Left err)
  pure (decodeFirst {a} rows)

||| Whole-record replace of every non-pk column, keyed by `rec`'s own pk
||| field. `Right Nothing` (not an error) when no row has that id.
export
update : (Table a, ToRow a, FromRow a) => DB -> a -> IO (Either PGError (Maybe a))
update {a} db rec = do
  Right rows <- queryRows db (updateSql {a}) (updateParams {a} rec)
    | Left err => pure (Left err)
  pure (decodeFirst {a} rows)

||| `Right False` (not an error) when no row had that id.
export
deleteById : (Table a, ToField pk) => DB -> pk -> IO (Either PGError Bool)
deleteById {a} db pkVal = do
  Right rows <- queryRows db (deleteByIdSql {a}) [toField pkVal]
    | Left err => pure (Left err)
  case rows of
    [] => pure (Right False)
    _  => pure (Right True)

||| Per-field, single-column encode/decode typeclasses - the piece
||| `Derive.PGRow`'s `FromRow`/`ToRow` derivation chains together per
||| record field. Deliberately separate from `Data.PGValue`'s `getText`/
||| `getInt`/etc: those stay the low-level, no-typeclass-dispatch API;
||| this module is the new, opt-in layer built on top of them.
module DB.Field

import Data.PGValue

%default total

public export
interface FromField a where
  fromField : Row -> String -> Either String a

public export
interface ToField a where
  toField : a -> Maybe String

public export
FromField String where
  fromField = getText

public export
FromField Int where
  fromField = getInt

public export
FromField Integer where
  fromField = getInteger

public export
FromField Double where
  fromField = getDouble

public export
FromField Bool where
  fromField = getBool

||| Postgres's boolean text-format literal for `True`/`False`.
public export
boolText : Bool -> String
boolText True  = "true"
boolText False = "false"

public export
ToField String where
  toField = Just

public export
ToField Int where
  toField = Just . show

public export
ToField Integer where
  toField = Just . show

public export
ToField Double where
  toField = Just . show

public export
ToField Bool where
  toField = Just . boolText

||| The piece none of `Data.PGValue`'s raw getters support: a SQL NULL
||| decodes to `Nothing` instead of an error. `columnByName` (not
||| `getRawColumn`, which isn't exported) is what distinguishes "no such
||| column" from "NULL" from "has a value" here.
public export
FromField a => FromField (Maybe a) where
  fromField row col = case columnByName row col of
    Nothing       => Left ("No such column: " ++ col)
    Just Nothing  => Right Nothing
    Just (Just _) => map Just (fromField {a} row col)

public export
ToField a => ToField (Maybe a) where
  toField Nothing  = Nothing
  toField (Just x) = toField x

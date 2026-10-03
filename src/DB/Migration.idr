||| Explicit, forward-only SQL migrations on a dedicated connection.
||| No automatic schema diffing and no destructive-change inference.
module DB.Migration

import Idris2_pg
import public Data.PGTypes
import Data.PGValue
import Data.List
import Data.String
import Data.Utf8
import Crypto.SHA256

%default covering

public export
record Migration where
  constructor MkMigration
  version : Nat
  name : String
  statements : List String

-- Length framing prevents ambiguous concatenation. Store the SHA-256 bytes
-- in their stable decimal-list representation; this is not a password hash.
checksum : Migration -> String
checksum migration = show $ sha256 $ stringToBytes $
  concatMap (\sql => show (length sql) ++ ":" ++ sql) (migration.name :: migration.statements)

-- Conservative v1 SQL subset. Extended-query execution rejects multiple
-- statements in one entry; these leading forms exclude transaction control,
-- CALL, COPY and arbitrary migration runner/session configuration commands.
-- SQL remains trusted, reviewed application code, not end-user input.
allowed : String -> Bool
allowed sql = case map toUpper (words sql) of
  "CREATE" :: "TABLE" :: _ => True
  "ALTER" :: "TABLE" :: _ => True
  "DROP" :: "TABLE" :: _ => True
  "CREATE" :: "INDEX" :: _ => True
  "CREATE" :: "UNIQUE" :: "INDEX" :: _ => True
  "DROP" :: "INDEX" :: _ => True
  "INSERT" :: "INTO" :: _ => True
  "UPDATE" :: _ :: _ => True
  "DELETE" :: "FROM" :: _ => True
  _ => False

validate : Nat -> List Migration -> Either PGError ()
validate _ [] = Right ()
validate previous (m :: rest) =
  if m.version <= previous || m.version > 9223372036854775807
    then Left (ProtocolError "migration versions must be increasing positive BIGINTs")
    else if m.name == "" || null m.statements || not (all allowed m.statements)
      then Left (ProtocolError "migration requires a name and supported single-statement SQL entries")
      else validate m.version rest

pending : List Migration -> List Row -> Either PGError (List Migration)
pending migrations [] = Right migrations
pending [] (_ :: _) = Left (ProtocolError "database has migrations absent from this application")
pending (m :: rest) (row :: rows) =
  if columnByName row "version" == Just (Just (show m.version)) &&
     columnByName row "name" == Just (Just m.name) &&
     columnByName row "checksum" == Just (Just (checksum m))
    then pending rest rows
    else Left (ProtocolError "migration history mismatch: version, name or checksum changed")

commands : DB -> List String -> IO (Either PGError ())
commands _ [] = pure (Right ())
commands db (sql :: rest) = do
  Right _ <- execCommandPrepared db sql [] | Left err => pure (Left err)
  commands db rest

applyOne : DB -> Migration -> IO (Either PGError ())
applyOne db m = withTransaction db $ do
  Right _ <- commands db m.statements | Left err => pure (Left err)
  Right _ <- execCommand db
    "INSERT INTO flux_db_meta.migrations(version, name, checksum) VALUES ($1::bigint, $2, $3)"
    [Just (show m.version), Just m.name, Just (checksum m)]
    | Left err => pure (Left err)
  pure (Right ())

applyAll : DB -> Nat -> List Migration -> IO (Either PGError Nat)
applyAll _ count [] = pure (Right count)
applyAll db count (m :: rest) = do
  Right _ <- applyOne db m | Left err => pure (Left err)
  applyAll db (S count) rest

-- A renamed runner must never create an empty history beside an existing
-- pre-rename database. Require an explicit, reviewed metadata cutover instead.
prepareMetadata : DB -> IO (Either PGError ())
prepareMetadata db = do
  Right [row] <- queryRows db
    "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'nebula_meta') AS legacy" []
    | Left err => pure (Left err)
    | Right _ => pure (Left (ProtocolError "unexpected migration metadata response"))
  if columnByName row "legacy" /= Just (Just "f")
    then pure (Left (ProtocolError "Legacy nebula_meta schema detected; stop migration runners and follow the Flux DB metadata cutover guide before retrying. No migrations were applied."))
    else commands db
      [ "CREATE SCHEMA IF NOT EXISTS flux_db_meta"
      , "CREATE TABLE IF NOT EXISTS flux_db_meta.migrations (version bigint PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())"
      ]

runOn : DB -> List Migration -> IO (Either PGError Nat)
runOn db migrations = do
  Right [row] <- queryRows db "SELECT pg_try_advisory_lock(723946218534101) AS acquired" []
    | Left err => pure (Left err)
    | Right _ => pure (Left (ProtocolError "unexpected migration lock response"))
  if columnByName row "acquired" /= Just (Just "t")
    then pure (Left (ProtocolError "another migration runner holds the database lock"))
    else do
      Right _ <- prepareMetadata db | Left err => pure (Left err)
      Right rows <- queryRows db "SELECT version, name, checksum FROM flux_db_meta.migrations ORDER BY version" []
        | Left err => pure (Left err)
      case pending migrations rows of
        Left err => pure (Left err)
        Right todo => applyAll db 0 todo

||| Apply a complete ordered migration history, returning the number applied.
||| Uses a fresh, exclusive connection; closing it releases the session advisory
||| lock even after errors/timeouts. Each migration's PostgreSQL changes and
||| history row commit together. Earlier successful migrations remain committed
||| if a later migration fails. Supply explicit transport deadlines in config.
||| Only the documented transactional SQL subset is supported. SQL must be
||| reviewed trusted code and must not mutate flux_db_meta or release its lock.
export
runMigrations : PGConfig -> List Migration -> IO (Either PGError Nat)
runMigrations config migrations = case validate 0 migrations of
  Left err => pure (Left err)
  Right _ => do
    Right db <- connectDB config | Left err => pure (Left err)
    result <- runOn db migrations
    closeDB db
    pure result

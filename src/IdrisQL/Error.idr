module IdrisQL.Error

%default total

||| A position in SQL source text, 1-based.
public export
record Pos where
  constructor MkPos
  line : Nat
  col : Nat

public export
Eq Pos where
  a == b = a.line == b.line && a.col == b.col

public export
Show Pos where
  show p = show p.line ++ ":" ++ show p.col

public export
data DbError
  = ||| A filesystem operation failed.
    IOFailure String
  | ||| Stored bytes violate a format invariant (bad checksum, bad offset, ...).
    Corrupt String
  | SyntaxError Pos String
  | ||| Name resolution or type checking rejected the statement.
    SemanticError String
  | ConstraintViolation String
  | ||| Evaluation failed on a well-typed statement (for example overflow).
    RuntimeError String
  | ||| A transaction command was issued in the wrong state.
    TxError String
  | ||| The database is held by another process, or by a crashed one.
    Locked String
  | Unsupported String
  | ||| Raised by the fault-injecting storage layer in tests.
    InjectedFault String

public export
Show DbError where
  show (IOFailure s) = "I/O error: " ++ s
  show (Corrupt s) = "corrupt database: " ++ s
  show (SyntaxError p s) = "syntax error at " ++ show p ++ ": " ++ s
  show (SemanticError s) = "error: " ++ s
  show (ConstraintViolation s) = "constraint violation: " ++ s
  show (RuntimeError s) = "runtime error: " ++ s
  show (TxError s) = "transaction error: " ++ s
  show (Locked s) = "database locked: " ++ s
  show (Unsupported s) = "not supported: " ++ s
  show (InjectedFault s) = "injected fault: " ++ s

||| IO with typed failure. Every engine operation that touches storage runs
||| here, so an I/O or corruption error is a value, never a crash.
public export
record DB a where
  constructor MkDB
  runDB : IO (Either DbError a)

public export
Functor DB where
  map f (MkDB m) = MkDB (map (map f) m)

public export
Applicative DB where
  pure x = MkDB (pure (Right x))
  MkDB mf <*> MkDB mx = MkDB $ do
    Right f <- mf | Left e => pure (Left e)
    Right x <- mx | Left e => pure (Left e)
    pure (Right (f x))

public export
Monad DB where
  MkDB m >>= k = MkDB $ do
    Right x <- m | Left e => pure (Left e)
    runDB (k x)

public export
HasIO DB where
  liftIO m = MkDB (map Right m)

export
throw : DbError -> DB a
throw e = MkDB (pure (Left e))

export
liftE : Either DbError a -> DB a
liftE r = MkDB (pure r)

export
catchDB : DB a -> (DbError -> DB a) -> DB a
catchDB (MkDB m) h = MkDB $ do
  Left e <- m | Right x => pure (Right x)
  runDB (h e)

||| Run `cleanup` after `act` whether or not `act` failed; the error of `act`
||| wins if both fail.
export
finally : DB a -> DB () -> DB a
finally (MkDB act) (MkDB cleanup) = MkDB $ do
  r <- act
  c <- cleanup
  pure $ case (r, c) of
    (Left e, _) => Left e
    (Right _, Left e) => Left e
    (Right x, Right ()) => Right x

export
when' : Bool -> DbError -> DB ()
when' cond e = if cond then throw e else pure ()

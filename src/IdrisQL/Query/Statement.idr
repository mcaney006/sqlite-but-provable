module IdrisQL.Query.Statement

import Data.List
import Data.List.Elem
import Data.Maybe
import Data.String
import IdrisQL.Catalog.Schema
import IdrisQL.Error
import IdrisQL.Query.Algebra
import IdrisQL.Query.Optimizer
import IdrisQL.Query.Planner
import IdrisQL.SQL.AST
import IdrisQL.SQL.Analyzer
import IdrisQL.SQL.Parser
import IdrisQL.SQL.Typed
import IdrisQL.Types

-- Checked statements. `compile` does all name resolution and type checking
-- for a statement against the current schema; what it returns can be run
-- without any further lookup that could fail for reasons other than the
-- data itself.

||| `column = expr` in an UPDATE: the expression has the column's type.
public export
data Assignment : List SqlType -> Type where
  MkAssignment : (t : SqlType) -> Elem t ctx -> TExpr ctx t -> Assignment ctx

public export
record Check (ctx : List SqlType) where
  constructor MkCheck
  sql : String
  expr : TExpr ctx TBool

public export
data Compiled : Type where
  CSelect  : (q : Query) -> PPlan q.shape -> Compiled
  ||| One expression row per VALUES row, each of the table's exact shape.
  CInsert  : (tbl : TableDef) -> (rows : List (Exprs [] (tableCtx tbl))) ->
             (checks : List (Check (tableCtx tbl))) -> (indexes : List IndexDef) -> Compiled
  CUpdate  : (tbl : TableDef) -> List (Assignment (tableCtx tbl)) ->
             (pred : Maybe (TExpr (tableCtx tbl) TBool)) -> Access [] ->
             (checks : List (Check (tableCtx tbl))) -> (indexes : List IndexDef) -> Compiled
  CDelete  : (tbl : TableDef) -> (pred : Maybe (TExpr (tableCtx tbl) TBool)) -> Access [] ->
             (indexes : List IndexDef) -> Compiled
  CExplain : List String -> Compiled
  ||| DDL and transaction control, which the engine interprets directly.
  CDirect  : Stmt -> Compiled

export
tableEnv : (tbl : TableDef) -> Env (tableCtx tbl)
tableEnv tbl = plainEnv (tableScope tbl.name tbl.columns)

export
tableChecks : (tbl : TableDef) -> Either DbError (List (Check (tableCtx tbl)))
tableChecks tbl = traverse one tbl.checks
  where
    one : String -> Either DbError (Check (tableCtx tbl))
    one sql = do
      e <- parseExpr sql
      x <- check (tableEnv tbl) TBool e
      Right (MkCheck sql x)

findTableAt : Schema -> Pos -> String -> Either DbError TableDef
findTableAt schema p name = case findTable schema name of
  Just tbl => Right tbl
  Nothing => Left (err p ("no such table: " ++ name))

duplicate : List String -> Maybe String
duplicate [] = Nothing
duplicate (x :: xs) = if norm x `elem` map norm xs then Just x else duplicate xs

-- One expression per table column, in table order: the given value, else
-- the column's DEFAULT, else NULL.
rowExprs : (cols : List ColumnDef) -> (given : List (String, Expr)) ->
           Either DbError (Exprs [] (map (.type) cols))
rowExprs [] given = Right []
rowExprs (c :: cs) given = do
  e <- case lookup (norm c.name) given of
         Just e => checkConstant c.type e
         Nothing => case c.defaultSql of
           Just sql => parseExpr sql >>= checkConstant c.type
           Nothing => Right (Lit c.type Nothing)
  rest <- rowExprs cs given
  Right (e :: rest)

compileInsert : Schema -> Pos -> String -> Maybe (List String) -> List (List Expr) -> Either DbError Compiled
compileInsert schema p table cols rows = do
  tbl <- findTableAt schema p table
  let names = fromMaybe (map (.name) tbl.columns) cols
  case duplicate names of
    Just n => Left (err p ("column " ++ n ++ " is listed twice"))
    Nothing => pure ()
  for_ names $ \n => case columnIndex tbl n of
    Just _ => Right ()
    Nothing => Left (err p ("table " ++ tbl.name ++ " has no column named " ++ n))
  exprs <- traverse (one tbl names) rows
  checks <- tableChecks tbl
  Right (CInsert tbl exprs checks (tableIndexes schema tbl.name))
  where
    one : (tbl : TableDef) -> List String -> List Expr -> Either DbError (Exprs [] (tableCtx tbl))
    one tbl names values =
      if length values /= length names
        then Left (err p (show (length values) ++ " values for " ++ show (length names) ++ " columns"))
        else rowExprs tbl.columns (zip (map norm names) values)

compileUpdate : Schema -> Pos -> String -> List (String, Expr) -> Maybe Expr -> Either DbError Compiled
compileUpdate schema p table sets pred = do
  tbl <- findTableAt schema p table
  case duplicate (map fst sets) of
    Just n => Left (err p ("column " ++ n ++ " is assigned twice"))
    Nothing => pure ()
  let env = tableEnv tbl
  assigns <- traverse (one tbl env) sets
  cond <- traverse (check env TBool) pred
  checks <- tableChecks tbl
  Right (CUpdate tbl assigns cond (accessFor schema tbl cond) checks (tableIndexes schema tbl.name))
  where
    one : (tbl : TableDef) -> Env (tableCtx tbl) -> (String, Expr) -> Either DbError (Assignment (tableCtx tbl))
    one tbl env (name, e) = case resolveColumn env.scope name of
      Nothing => Left (err p ("table " ++ tbl.name ++ " has no column named " ++ name))
      Just (MkFound t el) => do
        x <- check env t e
        Right (MkAssignment t el x)

compileDelete : Schema -> Pos -> String -> Maybe Expr -> Either DbError Compiled
compileDelete schema p table pred = do
  tbl <- findTableAt schema p table
  cond <- traverse (check (tableEnv tbl) TBool) pred
  Right (CDelete tbl cond (accessFor schema tbl cond) (tableIndexes schema tbl.name))

section : String -> List String -> List String
section title ls = title :: map ("  " ++) ls

mutual
  ||| Check a statement against the schema.
  export
  compile : Schema -> Stmt -> Either DbError Compiled
  compile schema (SSelect sel) = do
    q <- analyzeSelect schema sel
    Right (CSelect q (planQuery schema q))
  compile schema (SInsert p table cols rows) = compileInsert schema p table cols rows
  compile schema (SUpdate p table sets pred) = compileUpdate schema p table sets pred
  compile schema (SDelete p table pred) = compileDelete schema p table pred
  compile schema (SExplain queryPlan inner) = map CExplain (explain schema queryPlan inner)
  compile schema s = Right (CDirect s)

  explain : Schema -> (queryPlan : Bool) -> Stmt -> Either DbError (List String)
  explain schema queryPlan (SSelect sel) = do
    q <- analyzeSelect schema sel
    let physical = explainPlan (planQuery schema q)
    Right (if queryPlan then physical
           else section "LOGICAL PLAN" (explainLogical q.plan)
                ++ section "AFTER REWRITES" (explainLogical (optimize q.plan))
                ++ section "PHYSICAL PLAN" physical)
  explain schema queryPlan s@(SInsert _ _ _ _) = do
    CInsert tbl rows _ _ <- compile schema s
      | _ => Left (SemanticError "internal: INSERT compiled to another statement")
    Right ["INSERT INTO " ++ tbl.name ++ " (" ++ show (length rows) ++ " rows)"]
  explain schema queryPlan s@(SUpdate _ _ _ _) = do
    CUpdate tbl _ _ access _ _ <- compile schema s
      | _ => Left (SemanticError "internal: UPDATE compiled to another statement")
    Right ["UPDATE " ++ tbl.name, "  " ++ explainAccess tbl access]
  explain schema queryPlan s@(SDelete _ _ _) = do
    CDelete tbl _ access _ <- compile schema s
      | _ => Left (SemanticError "internal: DELETE compiled to another statement")
    Right ["DELETE FROM " ++ tbl.name, "  " ++ explainAccess tbl access]
  explain schema queryPlan _ =
    Left (Unsupported "EXPLAIN applies to SELECT, INSERT, UPDATE and DELETE")

assignmentParams : Assignment ctx -> List (Nat, SqlType)
assignmentParams (MkAssignment _ _ e) = paramsOf e

||| Index and required type of every parameter in a statement.
export
compiledParams : Compiled -> List (Nat, SqlType)
compiledParams (CSelect q _) = planParams q.plan
compiledParams (CInsert _ rows _ _) = concatMap paramsOfExprs rows
compiledParams (CUpdate _ assigns pred _ _ _) = concatMap assignmentParams assigns ++ maybe [] paramsOf pred
compiledParams (CDelete _ pred _ _) = maybe [] paramsOf pred
compiledParams (CExplain _) = []
compiledParams (CDirect _) = []

||| Every parameter must be bound to a value of the type its position
||| requires. After this check no parameter lookup can fail at run time.
export
checkParams : List (Nat, SqlType) -> List Value -> Either DbError ()
checkParams [] values = Right ()
checkParams ((i, t) :: rest) values = case getAt i values of
  Nothing => Left (RuntimeError ("parameter ?" ++ show (S i) ++ " is not bound"))
  Just v => case fromValue t v of
    Just _ => checkParams rest values
    Nothing => Left (RuntimeError ("parameter ?" ++ show (S i) ++ " must be " ++ show t
                                   ++ ", got " ++ show v))

-- CREATE TABLE.

primaryKeys : List ColumnSpec -> List TableConstraint -> List (List String)
primaryKeys cols cons =
  mapMaybe (\c => if any isPk c.constraints then Just [c.name] else Nothing) cols
  ++ mapMaybe (\c => case c of
                       TCPrimaryKey names => Just names
                       _ => Nothing) cons
  where
    isPk : ColConstraint -> Bool
    isPk CPrimaryKey = True
    isPk _ = False

uniqueSets : List ColumnSpec -> List TableConstraint -> List (List String)
uniqueSets cols cons =
  mapMaybe (\c => if any isUnique c.constraints then Just [c.name] else Nothing) cols
  ++ mapMaybe (\c => case c of
                       TCUnique names => Just names
                       _ => Nothing) cons
  where
    isUnique : ColConstraint -> Bool
    isUnique CUnique = True
    isUnique _ = False

hasNotNull : ColumnSpec -> Bool
hasNotNull c = any (\k => case k of
                            CNotNull => True
                            _ => False) c.constraints

defaultOf : ColumnSpec -> Either DbError (Maybe String)
defaultOf c = case mapMaybe (\k => case k of
                                     CDefault e => Just e
                                     _ => Nothing) c.constraints of
  [] => Right Nothing
  [e] => do
    x <- checkConstant c.type e
    if isNil (paramsOf x) then Right (Just (renderExpr e))
      else Left (SemanticError ("the DEFAULT of column " ++ c.name ++ " uses a parameter"))
  _ => Left (SemanticError ("column " ++ c.name ++ " has more than one DEFAULT"))

positionOf : List ColumnSpec -> String -> Maybe Nat
positionOf specs name = go 0 specs
  where
    go : Nat -> List ColumnSpec -> Maybe Nat
    go _ [] = Nothing
    go i (c :: cs) = if norm c.name == norm name then Just i else go (S i) cs

||| The definitions a CREATE TABLE produces: the table and one index per
||| PRIMARY KEY or UNIQUE constraint that is not the rowid. Ids and root
||| pages are filled in by the engine.
export
planCreateTable : (name : String) -> List ColumnSpec -> List TableConstraint ->
                  Either DbError (TableDef, List IndexDef)
planCreateTable name specs cons = do
  case duplicate (map (.name) specs) of
    Just n => Left (SemanticError ("duplicate column name: " ++ n))
    Nothing => pure ()
  pk <- case primaryKeys specs cons of
          [] => Right Nothing
          [cols] => Right (Just cols)
          _ => Left (SemanticError ("table " ++ name ++ " has more than one primary key"))
  let position = positionOf specs
  let rowidColumn = case pk of
        Just [n] => case find (\c => norm c.name == norm n) specs of
                      Just c => if c.type == TInt then position n else Nothing
                      Nothing => Nothing
        _ => Nothing
  let pkNames = maybe [] (map norm) pk
  columns <- traverse (\c => do
                dflt <- defaultOf c
                let viaPk = isNothing rowidColumn && (norm c.name `elem` pkNames)
                Right (MkColumnDef c.name c.type (hasNotNull c || viaPk) dflt)) specs
  let draft = MkTableDef 0 name 0 columns rowidColumn [] [] (-1)
  let checkExprs = concatMap (\c => mapMaybe (\k => case k of
                                                      CCheck e => Just e
                                                      _ => Nothing) c.constraints) specs
                   ++ mapMaybe (\c => case c of
                                        TCCheck e => Just e
                                        _ => Nothing) cons
  checks <- traverse (\e => do
               x <- check (tableEnv draft) TBool e
               if isNil (paramsOf x) then Right (renderExpr e)
                 else Left (SemanticError "a CHECK constraint uses a parameter")) checkExprs
  let fks = concatMap (\c => mapMaybe (\k => case k of
                                               CReferences t cols => Just (MkForeignKeyDef [c.name] t cols)
                                               _ => Nothing) c.constraints) specs
            ++ mapMaybe (\c => case c of
                                 TCForeignKey cols t refs => Just (MkForeignKeyDef cols t refs)
                                 _ => Nothing) cons
  let keySets = (if isNothing rowidColumn then toList (map (\cols => (name ++ "_pkey", cols)) pk) else [])
                ++ map (\cols => (name ++ "_" ++ concat (intersperse "_" cols) ++ "_key", cols))
                       (uniqueSets specs cons)
  indexes <- traverse (\(iname, cols) => do
                positions <- traverse (\n => case position n of
                               Just i => Right i
                               Nothing => Left (SemanticError ("constraint names unknown column " ++ n))) cols
                Right (MkIndexDef 0 iname name 0 positions True True (-1))) keySets
  Right ({ checks := checks, foreignKeys := fks } draft,
         distinctNames [] (nubBy (\a, b => a.columns == b.columns) indexes))
  where
    -- UNIQUE (a_b) and UNIQUE (a, b) would both be named <table>_a_b_key.
    -- A repeated name gets the lowest number that makes it new.
    numbered : List String -> String -> Nat -> Nat -> String
    numbered taken base n Z = base ++ show n
    numbered taken base n (S fuel) =
      if (base ++ show n) `elem` taken then numbered taken base (S n) fuel else base ++ show n

    distinctNames : List String -> List IndexDef -> List IndexDef
    distinctNames taken [] = []
    distinctNames taken (i :: rest) =
      let fresh = if i.name `elem` taken then numbered taken i.name 2 (length taken) else i.name
      in { name := fresh } i :: distinctNames (fresh :: taken) rest

-- Schema as SQL text, for the shell's .schema command.

columnSql : TableDef -> (Nat, ColumnDef) -> String
columnSql tbl (i, c) =
  quoteIdent c.name ++ " " ++ show c.type
    ++ (if tbl.rowidColumn == Just i then " PRIMARY KEY" else "")
    ++ (if c.notNull then " NOT NULL" else "")
    ++ maybe "" (\d => " DEFAULT " ++ d) c.defaultSql

numbered : List a -> List (Nat, a)
numbered xs = go 0 xs
  where
    go : Nat -> List a -> List (Nat, a)
    go _ [] = []
    go i (y :: ys) = (i, y) :: go (S i) ys

columnList : TableDef -> List Nat -> String
columnList tbl cols =
  concat (intersperse ", " (map (\i => maybe "?" (quoteIdent . (.name)) (getAt i tbl.columns)) cols))

names : List String -> String
names = concat . intersperse ", " . map quoteIdent

keyLine : TableDef -> IndexDef -> String
keyLine tbl i =
  (if isSuffixOf "_pkey" i.name then "PRIMARY KEY (" else "UNIQUE (") ++ columnList tbl i.columns ++ ")"

foreignKeyLine : ForeignKeyDef -> String
foreignKeyLine fk =
  "FOREIGN KEY (" ++ names fk.columns ++ ") REFERENCES " ++ quoteIdent fk.refTable
    ++ (if isNil fk.refColumns then "" else " (" ++ names fk.refColumns ++ ")")

indexSql : TableDef -> IndexDef -> String
indexSql tbl i =
  "CREATE " ++ (if i.unique then "UNIQUE " else "") ++ "INDEX " ++ quoteIdent i.name
    ++ " ON " ++ quoteIdent tbl.name ++ " (" ++ columnList tbl i.columns ++ ");"

||| CREATE statements that would rebuild a table and its indexes.
export
tableSql : TableDef -> List IndexDef -> List String
tableSql tbl indexes =
  let owned : List IndexDef = filter (\i => i.constraintOwned) indexes
      free : List IndexDef = filter (\i => not i.constraintOwned) indexes
      parts : List String = map (columnSql tbl) (numbered tbl.columns)
                            ++ map (keyLine tbl) owned
                            ++ map ("CHECK " ++) tbl.checks
                            ++ map foreignKeyLine tbl.foreignKeys
      create = "CREATE TABLE " ++ quoteIdent tbl.name ++ " (\n  "
               ++ concat (intersperse ",\n  " parts) ++ "\n);"
  in create :: map (indexSql tbl) free

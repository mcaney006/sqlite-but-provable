module IdrisQL.SQL.Parser

import Data.List
import Data.SnocList
import Data.String
import IdrisQL.Error
import IdrisQL.SQL.AST
import IdrisQL.SQL.Lexer
import IdrisQL.SQL.Token
import IdrisQL.Types

-- Recursive descent over the token list. The functions here are covering
-- but not structurally terminating; every loop consumes a token before it
-- recurses, and the token list is finite.

record PState where
  constructor MkPState
  ||| Remaining tokens. The final `EOFTok` is never consumed.
  toks : List Token
  ||| Index the next bare `?` receives.
  nextParam : Nat

record P a where
  constructor MkP
  runP : PState -> Either DbError (a, PState)

Functor P where
  map f (MkP g) = MkP $ \s => case g s of
    Left e => Left e
    Right (x, s') => Right (f x, s')

Applicative P where
  pure x = MkP $ \s => Right (x, s)
  MkP f <*> MkP g = MkP $ \s => case f s of
    Left e => Left e
    Right (h, s') => case g s' of
      Left e => Left e
      Right (x, s'') => Right (h x, s'')

Monad P where
  MkP g >>= k = MkP $ \s => case g s of
    Left e => Left e
    Right (x, s') => runP (k x) s'

peek : P Token
peek = MkP $ \s => case s.toks of
  (t :: _) => Right (t, s)
  [] => Right (MkToken (MkPos 1 1) EOFTok, s)

peekAt : Nat -> P TokKind
peekAt n = MkP $ \s => case drop n s.toks of
  (t :: _) => Right (t.kind, s)
  [] => Right (EOFTok, s)

peekKind : P TokKind
peekKind = peekAt 0

advance : P ()
advance = MkP $ \s => case s.toks of
  (_ :: rest@(_ :: _)) => Right ((), { toks := rest } s)
  _ => Right ((), s)

failAt : Pos -> String -> P a
failAt p msg = MkP $ \_ => Left (SyntaxError p msg)

failHere : String -> P a
failHere msg = do
  t <- peek
  failAt t.pos msg

expected : String -> P a
expected what = do
  t <- peek
  failAt t.pos ("expected " ++ what ++ " but found " ++ describe t.kind)

||| Matches a word whether or not the lexer treats it as reserved.
isWord : String -> TokKind -> Bool
isWord w (KwTok k) = k == w
isWord w (IdentTok s) = toUpper s == w
isWord _ _ = False

isSym : String -> TokKind -> Bool
isSym s (SymTok t) = s == t
isSym _ _ = False

isName : TokKind -> Bool
isName (IdentTok _) = True
isName (QuotedTok _) = True
isName _ = False

isEOF : TokKind -> Bool
isEOF EOFTok = True
isEOF _ = False

acceptWord : String -> P Bool
acceptWord w = do
  k <- peekKind
  if isWord w k then advance >> pure True else pure False

expectWord : String -> P ()
expectWord w = do
  ok <- acceptWord w
  if ok then pure () else expected ("'" ++ w ++ "'")

acceptSym : String -> P Bool
acceptSym s = do
  k <- peekKind
  if isSym s k then advance >> pure True else pure False

expectSym : String -> P ()
expectSym s = do
  ok <- acceptSym s
  if ok then pure () else expected ("'" ++ s ++ "'")

identifier : (what : String) -> P String
identifier what = do
  t <- peek
  case t.kind of
    IdentTok s => advance >> pure s
    QuotedTok s => advance >> pure s
    _ => expected what

commaSep1 : P a -> P (List a)
commaSep1 p = go [<]
  where
    go : SnocList a -> P (List a)
    go acc = do
      x <- p
      more <- acceptSym ","
      if more then go (acc :< x) else pure (acc <>> [x])

identList : (what : String) -> P (List String)
identList what = do
  expectSym "("
  xs <- commaSep1 (identifier what)
  expectSym ")"
  pure xs

optLength : P ()
optLength = do
  True <- acceptSym "(" | False => pure ()
  IntTok _ <- peekKind | _ => expected "a length"
  advance
  expectSym ")"

sqlType : P SqlType
sqlType = do
  t <- peek
  case t.kind of
    IdentTok s => do
      advance
      case toUpper s of
        "INTEGER" => pure TInt
        "INT" => pure TInt
        "BIGINT" => pure TInt
        "SMALLINT" => pure TInt
        "REAL" => pure TReal
        "FLOAT" => pure TReal
        "DOUBLE" => do
          _ <- acceptWord "PRECISION"
          pure TReal
        "TEXT" => pure TText
        "STRING" => pure TText
        "VARCHAR" => optLength >> pure TText
        "CHAR" => optLength >> pure TText
        "BLOB" => pure TBlob
        "BOOLEAN" => pure TBool
        "BOOL" => pure TBool
        _ => failAt t.pos ("unknown type '" ++ s ++ "'")
    _ => expected "a type name"

literal : (what : String) -> P Expr
literal what = do
  t <- peek
  let lit = \l => advance >> pure (ELit t.pos l)
  case t.kind of
    IntTok n => lit (LInt n)
    RealTok d => lit (LReal d)
    StrTok s => lit (LText s)
    BlobTok b => lit (LBlob b)
    KwTok "NULL" => lit LNull
    KwTok "TRUE" => lit (LBool True)
    KwTok "FALSE" => lit (LBool False)
    _ => expected what

-- A bare `?` takes the index after the largest one used so far, so `?`
-- alone numbers parameters 0, 1, 2 in order of appearance.
param : Pos -> Maybe Nat -> P Expr
param p Nothing = MkP $ \s => Right (EParam p s.nextParam, { nextParam $= S } s)
param p (Just n) = MkP $ \s => Right (EParam p (minus n 1), { nextParam := max s.nextParam n } s)

symOp : (String -> Maybe BinOp) -> TokKind -> Maybe BinOp
symOp ops (SymTok s) = ops s
symOp _ _ = Nothing

cmpOp : String -> Maybe BinOp
cmpOp "=" = Just OEq
cmpOp "==" = Just OEq
cmpOp "!=" = Just ONe
cmpOp "<>" = Just ONe
cmpOp "<" = Just OLt
cmpOp "<=" = Just OLe
cmpOp ">" = Just OGt
cmpOp ">=" = Just OGe
cmpOp _ = Nothing

addOp : String -> Maybe BinOp
addOp "+" = Just OAdd
addOp "-" = Just OSub
addOp _ = Nothing

mulOp : String -> Maybe BinOp
mulOp "*" = Just OMul
mulOp "/" = Just ODiv
mulOp "%" = Just OMod
mulOp _ = Nothing

concatOp : String -> Maybe BinOp
concatOp "||" = Just OConcat
concatOp _ = Nothing

-- A window clause after a function call: OVER ( ... ) or OVER name.
rejectWindow : P ()
rejectWindow = do
  k0 <- peekKind
  k1 <- peekAt 1
  if isWord "OVER" k0 && (isSym "(" k1 || isName k1)
    then failHere "window functions are not supported"
    else pure ()

mutual
  expr : P Expr
  expr = do
    l <- andExpr
    orRest l

  orRest : Expr -> P Expr
  orRest l = do
    True <- acceptWord "OR" | False => pure l
    r <- andExpr
    orRest (EBin (exprPos l) OOr l r)

  andExpr : P Expr
  andExpr = do
    l <- notExpr
    andRest l

  andRest : Expr -> P Expr
  andRest l = do
    True <- acceptWord "AND" | False => pure l
    r <- notExpr
    andRest (EBin (exprPos l) OAnd l r)

  notExpr : P Expr
  notExpr = do
    t <- peek
    if isWord "NOT" t.kind
      then do
        advance
        e <- notExpr
        pure (ENot t.pos e)
      else do
        l <- addExpr
        cmpRest l

  -- Comparison level: binary comparisons and the postfix predicates, all
  -- left-associative.
  cmpRest : Expr -> P Expr
  cmpRest l = do
    k <- peekKind
    k1 <- peekAt 1
    case symOp cmpOp k of
      Just op => do
        advance
        r <- addExpr
        cmpRest (EBin (exprPos l) op l r)
      Nothing =>
        if isWord "IS" k then do
            advance
            negated <- acceptWord "NOT"
            expectWord "NULL"
            cmpRest (EIsNull (exprPos l) negated l)
          else if isWord "NOT" k && (isWord "IN" k1 || isWord "BETWEEN" k1 || isWord "LIKE" k1) then do
            advance
            predicate True l
          else if isWord "IN" k || isWord "BETWEEN" k || isWord "LIKE" k then predicate False l
          else pure l

  predicate : (negated : Bool) -> Expr -> P Expr
  predicate negated l = do
    k <- peekKind
    advance
    if isWord "IN" k then do
        expectSym "("
        k' <- peekKind
        if isWord "SELECT" k'
          then failHere "subqueries are not supported"
          else do
            xs <- exprsUntilParen
            expectSym ")"
            cmpRest (EIn (exprPos l) negated l xs)
      else if isWord "BETWEEN" k then do
        lo <- addExpr
        expectWord "AND"
        hi <- addExpr
        cmpRest (EBetween (exprPos l) negated l lo hi)
      else do
        pat <- addExpr
        cmpRest (ELike (exprPos l) negated l pat)

  addExpr : P Expr
  addExpr = do
    l <- mulExpr
    addRest l

  addRest : Expr -> P Expr
  addRest l = do
    k <- peekKind
    case symOp addOp k of
      Nothing => pure l
      Just op => do
        advance
        r <- mulExpr
        addRest (EBin (exprPos l) op l r)

  mulExpr : P Expr
  mulExpr = do
    l <- concatExpr
    mulRest l

  mulRest : Expr -> P Expr
  mulRest l = do
    k <- peekKind
    case symOp mulOp k of
      Nothing => pure l
      Just op => do
        advance
        r <- concatExpr
        mulRest (EBin (exprPos l) op l r)

  concatExpr : P Expr
  concatExpr = do
    l <- unary
    concatRest l

  concatRest : Expr -> P Expr
  concatRest l = do
    k <- peekKind
    case symOp concatOp k of
      Nothing => pure l
      Just op => do
        advance
        r <- unary
        concatRest (EBin (exprPos l) op l r)

  unary : P Expr
  unary = do
    t <- peek
    if isSym "-" t.kind then do
        advance
        e <- unary
        pure (ENeg t.pos e)
      else if isSym "+" t.kind then advance >> unary
      else primary

  primary : P Expr
  primary = do
    t <- peek
    case t.kind of
      ParamTok m => advance >> param t.pos m
      SymTok "(" => do
        advance
        k <- peekKind
        if isWord "SELECT" k
          then failHere "subqueries are not supported"
          else do
            e <- expr
            expectSym ")"
            pure e
      KwTok "CAST" => do
        advance
        expectSym "("
        e <- expr
        expectWord "AS"
        ty <- sqlType
        expectSym ")"
        pure (ECast t.pos e ty)
      KwTok "EXISTS" => failAt t.pos "subqueries are not supported"
      KwTok "SELECT" => failAt t.pos "subqueries are not supported"
      KwTok "CASE" => failAt t.pos "CASE expressions are not supported"
      IdentTok s => advance >> nameOrCall t.pos s
      QuotedTok s => advance >> nameOrCall t.pos s
      _ => literal "an expression"

  -- After a name: a function call, a qualified column, or a bare column.
  nameOrCall : Pos -> String -> P Expr
  nameOrCall p name = do
    k <- peekKind
    if isSym "(" k then advance >> call p (toUpper name)
      else if isSym "." k then do
        advance
        column <- identifier "a column name"
        pure (ECol p (Just name) column)
      else pure (ECol p Nothing name)

  call : Pos -> String -> P Expr
  call p fname = do
    k <- peekKind
    if isSym "*" k
      then
        if fname == "COUNT"
          then do
            advance
            expectSym ")"
            rejectWindow
            pure (ECountStar p)
          else failHere "'*' as an argument is only valid in COUNT(*)"
      else do
        distinct <- acceptWord "DISTINCT"
        args <- exprsUntilParen
        expectSym ")"
        rejectWindow
        pure (ECall p fname distinct args)

  exprsUntilParen : P (List Expr)
  exprsUntilParen = do
    k <- peekKind
    if isSym ")" k then pure [] else commaSep1 expr

optAlias : P (Maybe String)
optAlias = do
  explicit <- acceptWord "AS"
  k <- peekKind
  if explicit || isName k then Just <$> identifier "an alias" else pure Nothing

selectItem : P SelectItem
selectItem = do
  k0 <- peekKind
  k1 <- peekAt 1
  k2 <- peekAt 2
  if isSym "*" k0 then advance >> pure SelStar
    else if isName k0 && isSym "." k1 && isSym "*" k2 then do
      table <- identifier "a table name"
      advance
      advance
      pure (SelTableStar table)
    else do
      e <- expr
      alias <- optAlias
      pure (SelExpr e alias)

tableRef : P TableRef
tableRef = do
  t <- peek
  if isSym "(" t.kind
    then failAt t.pos "subqueries are not supported"
    else do
      table <- identifier "a table name"
      alias <- optAlias
      pure (MkTableRef t.pos table alias)

joinOn : JoinKind -> P Join
joinOn kind = do
  expectWord "JOIN"
  ref <- tableRef
  expectWord "ON"
  on <- expr
  pure (MkJoin kind ref (Just on))

crossJoin : P Join
crossJoin = do
  ref <- tableRef
  pure (MkJoin JInner ref Nothing)

joins : SnocList Join -> P (List Join)
joins acc = do
  k <- peekKind
  if isSym "," k then do
      advance
      j <- crossJoin
      joins (acc :< j)
    else if isWord "CROSS" k then do
      advance
      expectWord "JOIN"
      j <- crossJoin
      joins (acc :< j)
    else if isWord "INNER" k then do
      advance
      j <- joinOn JInner
      joins (acc :< j)
    else if isWord "JOIN" k then do
      j <- joinOn JInner
      joins (acc :< j)
    else if isWord "LEFT" k then do
      advance
      _ <- acceptWord "OUTER"
      j <- joinOn JLeft
      joins (acc :< j)
    else if isWord "RIGHT" k then failHere "RIGHT JOIN is not supported"
    else if isWord "FULL" k then failHere "FULL JOIN is not supported"
    else pure (acc <>> [])

optClause : (keyword : String) -> P (Maybe Expr)
optClause keyword = do
  True <- acceptWord keyword | False => pure Nothing
  Just <$> expr

orderItem : P (Expr, SortDir)
orderItem = do
  e <- expr
  desc <- acceptWord "DESC"
  if desc then pure (e, Desc) else do
    _ <- acceptWord "ASC"
    pure (e, Asc)

selectStmt : P SelectStmt
selectStmt = do
  expectWord "SELECT"
  distinct <- acceptWord "DISTINCT"
  when (not distinct) $ ignore (acceptWord "ALL")
  items <- commaSep1 selectItem
  hasFrom <- acceptWord "FROM"
  from <- if hasFrom
            then do
              ref <- tableRef
              js <- joins [<]
              pure (Just (ref, js))
            else pure Nothing
  wh <- optClause "WHERE"
  hasGroup <- acceptWord "GROUP"
  groupBy <- if hasGroup then expectWord "BY" >> commaSep1 expr else pure []
  having <- optClause "HAVING"
  hasOrder <- acceptWord "ORDER"
  orderBy <- if hasOrder then expectWord "BY" >> commaSep1 orderItem else pure []
  limit <- optClause "LIMIT"
  offset <- case limit of
    Just _ => optClause "OFFSET"
    Nothing => pure Nothing
  pure (MkSelect distinct items from wh groupBy having orderBy limit offset)

-- DEFAULT takes a literal, a signed number, or a parenthesised expression.
defaultValue : P Expr
defaultValue = do
  t <- peek
  if isSym "(" t.kind then do
      advance
      e <- expr
      expectSym ")"
      pure e
    else if isSym "-" t.kind then do
      advance
      n <- number
      pure (ENeg t.pos n)
    else if isSym "+" t.kind then advance >> number
    else literal "a literal or a parenthesised expression"
  where
    number : P Expr
    number = do
      k <- peekKind
      case k of
        IntTok _ => literal "a number"
        RealTok _ => literal "a number"
        _ => expected "a number"

optIdentList : (what : String) -> P (List String)
optIdentList what = do
  k <- peekKind
  if isSym "(" k then identList what else pure []

-- The target of REFERENCES. Referential actions have no place in the AST.
referenceTarget : P (String, List String)
referenceTarget = do
  table <- identifier "a table name"
  cols <- optIdentList "a column name"
  k <- peekKind
  if isWord "ON" k
    then failHere "referential actions (ON DELETE, ON UPDATE) are not supported"
    else pure (table, cols)

checkExpr : P Expr
checkExpr = do
  expectSym "("
  e <- expr
  expectSym ")"
  pure e

colConstraints : SnocList ColConstraint -> P (List ColConstraint)
colConstraints acc = do
  k <- peekKind
  if isWord "CONSTRAINT" k then do
      advance
      _ <- identifier "a constraint name"
      colConstraints acc
    else if isWord "PRIMARY" k then do
      advance
      expectWord "KEY"
      colConstraints (acc :< CPrimaryKey)
    else if isWord "NOT" k then do
      advance
      expectWord "NULL"
      colConstraints (acc :< CNotNull)
    else if isWord "UNIQUE" k then do
      advance
      colConstraints (acc :< CUnique)
    else if isWord "DEFAULT" k then do
      advance
      e <- defaultValue
      colConstraints (acc :< CDefault e)
    else if isWord "CHECK" k then do
      advance
      e <- checkExpr
      colConstraints (acc :< CCheck e)
    else if isWord "REFERENCES" k then do
      advance
      (table, cols) <- referenceTarget
      colConstraints (acc :< CReferences table cols)
    else pure (acc <>> [])

columnSpec : P ColumnSpec
columnSpec = do
  name <- identifier "a column name"
  ty <- sqlType
  constraints <- colConstraints [<]
  pure (MkColumnSpec name ty constraints)

tableConstraintStart : TokKind -> Bool
tableConstraintStart k =
  isWord "CONSTRAINT" k || isWord "PRIMARY" k || isWord "UNIQUE" k
    || isWord "CHECK" k || isWord "FOREIGN" k

tableConstraint : P TableConstraint
tableConstraint = do
  named <- acceptWord "CONSTRAINT"
  when named $ ignore (identifier "a constraint name")
  k <- peekKind
  if isWord "PRIMARY" k then do
      advance
      expectWord "KEY"
      TCPrimaryKey <$> identList "a column name"
    else if isWord "UNIQUE" k then do
      advance
      TCUnique <$> identList "a column name"
    else if isWord "CHECK" k then do
      advance
      TCCheck <$> checkExpr
    else if isWord "FOREIGN" k then do
      advance
      expectWord "KEY"
      cols <- identList "a column name"
      expectWord "REFERENCES"
      (table, refCols) <- referenceTarget
      pure (TCForeignKey cols table refCols)
    else expected "PRIMARY KEY, UNIQUE, CHECK or FOREIGN KEY"

tableItems : SnocList ColumnSpec -> SnocList TableConstraint ->
             P (List ColumnSpec, List TableConstraint)
tableItems cols cons = do
  k <- peekKind
  (cols', cons') <- if tableConstraintStart k
                      then do
                        c <- tableConstraint
                        pure (cols, cons :< c)
                      else do
                        c <- columnSpec
                        pure (cols :< c, cons)
  more <- acceptSym ","
  if more then tableItems cols' cons' else pure (cols' <>> [], cons' <>> [])

ifNotExists : P Bool
ifNotExists = do
  k0 <- peekKind
  k1 <- peekAt 1
  if isWord "IF" k0 && isWord "NOT" k1
    then do
      advance
      advance
      expectWord "EXISTS"
      pure True
    else pure False

ifExists : P Bool
ifExists = do
  k0 <- peekKind
  k1 <- peekAt 1
  if isWord "IF" k0 && isWord "EXISTS" k1
    then do
      advance
      advance
      pure True
    else pure False

createTable : Pos -> P Stmt
createTable p = do
  guard <- ifNotExists
  name <- identifier "a table name"
  expectSym "("
  (cols, cons) <- tableItems [<] [<]
  expectSym ")"
  case cols of
    [] => failAt p "a table needs at least one column"
    _ => pure (SCreateTable p guard name cols cons)

indexColumn : P String
indexColumn = do
  name <- identifier "a column name"
  k <- peekKind
  if isWord "ASC" k || isWord "DESC" k
    then failHere "ASC and DESC on index columns are not supported"
    else pure name

createIndex : Pos -> (unique : Bool) -> P Stmt
createIndex p unique = do
  guard <- ifNotExists
  name <- identifier "an index name"
  expectWord "ON"
  table <- identifier "a table name"
  expectSym "("
  cols <- commaSep1 indexColumn
  expectSym ")"
  pure (SCreateIndex p unique guard name table cols)

create : Pos -> P Stmt
create p = do
  k <- peekKind
  if isWord "TABLE" k then advance >> createTable p
    else if isWord "INDEX" k then advance >> createIndex p False
    else if isWord "UNIQUE" k then do
      advance
      expectWord "INDEX"
      createIndex p True
    else expected "TABLE, INDEX or UNIQUE INDEX"

drop : Pos -> P Stmt
drop p = do
  k <- peekKind
  if isWord "TABLE" k then do
      advance
      guard <- ifExists
      SDropTable p guard <$> identifier "a table name"
    else if isWord "INDEX" k then do
      advance
      guard <- ifExists
      SDropIndex p guard <$> identifier "an index name"
    else expected "TABLE or INDEX"

valueRow : P (List Expr)
valueRow = do
  expectSym "("
  xs <- commaSep1 expr
  expectSym ")"
  pure xs

insert : Pos -> P Stmt
insert p = do
  expectWord "INTO"
  table <- identifier "a table name"
  k <- peekKind
  cols <- if isSym "(" k then Just <$> identList "a column name" else pure Nothing
  k' <- peekKind
  if isWord "SELECT" k'
    then failHere "INSERT ... SELECT is not supported"
    else do
      expectWord "VALUES"
      rows <- commaSep1 valueRow
      pure (SInsert p table cols rows)

assignment : P (String, Expr)
assignment = do
  col <- identifier "a column name"
  expectSym "="
  e <- expr
  pure (col, e)

update : Pos -> P Stmt
update p = do
  table <- identifier "a table name"
  expectWord "SET"
  sets <- commaSep1 assignment
  wh <- optClause "WHERE"
  pure (SUpdate p table sets wh)

delete : Pos -> P Stmt
delete p = do
  expectWord "FROM"
  table <- identifier "a table name"
  wh <- optClause "WHERE"
  pure (SDelete p table wh)

statement : P Stmt
statement = do
  t <- peek
  let k = t.kind
  let p = t.pos
  if isWord "SELECT" k then SSelect <$> selectStmt
    else if isWord "EXPLAIN" k then do
      advance
      k0 <- peekKind
      k1 <- peekAt 1
      queryPlan <- if isWord "QUERY" k0 && isWord "PLAN" k1
                     then advance >> advance >> pure True
                     else pure False
      SExplain queryPlan <$> statement
    else if isWord "CREATE" k then advance >> create p
    else if isWord "DROP" k then advance >> drop p
    else if isWord "INSERT" k then advance >> insert p
    else if isWord "UPDATE" k then advance >> update p
    else if isWord "DELETE" k then advance >> delete p
    else if isWord "BEGIN" k then do
      advance
      _ <- acceptWord "TRANSACTION"
      pure SBegin
    else if isWord "COMMIT" k || isWord "END" k then do
      advance
      _ <- acceptWord "TRANSACTION"
      pure SCommit
    else if isWord "ROLLBACK" k then do
      advance
      _ <- acceptWord "TRANSACTION"
      k' <- peekKind
      if isWord "TO" k' then failHere "savepoints are not supported" else pure SRollback
    else if isWord "ANALYZE" k then advance >> pure SAnalyze
    else if isWord "ALTER" k then failAt p "ALTER TABLE is not supported"
    else if isWord "SAVEPOINT" k || isWord "RELEASE" k then failAt p "savepoints are not supported"
    else expected "a statement"

-- What may follow a complete statement.
endOfStatement : P ()
endOfStatement = do
  t <- peek
  case t.kind of
    EOFTok => pure ()
    SymTok ";" => pure ()
    KwTok "UNION" => failAt t.pos "UNION is not supported"
    KwTok "INTERSECT" => failAt t.pos "INTERSECT is not supported"
    KwTok "EXCEPT" => failAt t.pos "EXCEPT is not supported"
    _ => expected "';' or end of input"

resetParams : P ()
resetParams = MkP $ \s => Right ((), { nextParam := 0 } s)

script : SnocList Stmt -> P (List Stmt)
script acc = do
  k <- peekKind
  if isSym ";" k then advance >> script acc
    else if isEOF k then pure (acc <>> [])
    else do
      resetParams
      s <- statement
      endOfStatement
      script (acc :< s)

single : P Stmt
single = do
  s <- statement
  endOfStatement
  trailing s
  where
    trailing : Stmt -> P Stmt
    trailing s = do
      k <- peekKind
      if isSym ";" k then advance >> trailing s
        else if isEOF k then pure s
        else expected "end of input"

singleExpr : P Expr
singleExpr = do
  e <- expr
  k <- peekKind
  if isEOF k then pure e else expected "end of input"

runParser : P a -> String -> Either DbError a
runParser p src = do
  toks <- tokenize src
  (x, _) <- runP p (MkPState toks 0)
  pure x

||| Parse exactly one statement. A trailing `;` is optional.
export
parseStatement : String -> Either DbError Stmt
parseStatement = runParser single

||| Parse a `;`-separated script. Empty statements are skipped.
export
parseStatements : String -> Either DbError (List Stmt)
parseStatements = runParser (script [<])

||| Parse one expression, such as the text `renderExpr` produces.
export
parseExpr : String -> Either DbError Expr
parseExpr = runParser singleExpr

module Ficus.Syntax.Parser (parseModule) where

import Control.Monad (void, when)
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.Trans.Class (lift)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Parser
import Ficus.Syntax.Concrete
import Ficus.Syntax.Parser.Lexer (eofSpan, lexSource)
import Text.Megaparsec hiding (Token, parse, tokens)

data Environment = Environment
  { floorColumn :: Int,
    itemLine :: Int,
    itemColumn :: Int,
    singleLine :: Maybe Int,
    fileEnd :: Span
  }

type Parser = ReaderT Environment (Parsec Diagnostic [Token])

parseModule :: FilePath -> Text -> Either Diagnostic ConcreteModule
parseModule file source = do
  (ts, cs) <- lexSource file source
  let ending = eofSpan file source
      env = Environment 1 1 1 Nothing ending
  (ps, is, ds) <- case runParser (runReaderT moduleParser env) file ts of
    Right result -> Right result
    Left bundle -> Left (fromError ts ending (firstError (bundleErrors bundle)))
  let s = Span file (Position 1 1 0) (end ending)
      result = ConcreteModule s (SourceOrigin s) ps is ds ts cs source
  case validateConcrete result of
    Left msg -> Left (Diagnostic InvalidConcreteTree s msg)
    Right () -> Right result
  where
    firstError (e :| _) = e
    fromError ts ending err = case err of
      FancyError _ details -> case [d | ErrorCustom d <- Set.toList details] of
        d : _ -> d
        [] -> ordinary ts ending err
      _ -> ordinary ts ending err
    ordinary ts ending err =
      Diagnostic
        UnexpectedToken
        (case drop (errorOffset err) ts of t : _ -> tokenSpan t; [] -> ending)
        "unexpected token or end of input"

peek :: Parser (Maybe Token)
peek = do
  ts <- getInput
  pure (case ts of t : _ -> Just t; [] -> Nothing)

available :: Token -> Parser Bool
available t = do
  env <- asks id
  let p = start (tokenSpan t)
  pure
    ( (line p <= itemLine env || column p > floorColumn env)
        && maybe True (line p <=) (singleLine env)
    )

accept :: (Token -> Bool) -> Parser Token
accept predicate = do
  mt <- peek
  case mt of
    Just t -> do
      ok <- available t
      if ok && predicate t then lift anySingle else empty
    Nothing -> empty

text :: Text -> Parser Token
text txt = accept ((== txt) . tokenText) <?> T.unpack txt

kind :: TokenKind -> Parser Token
kind k = accept ((== k) . tokenKind)

nextIs :: Text -> Parser Bool
nextIs txt = maybe False ((== txt) . tokenText) <$> peek

failHere :: ParserErrorCode -> Text -> Parser a
failHere k msg = do
  mt <- peek
  ending <- asks fileEnd
  customFailure (Diagnostic k (maybe ending tokenSpan mt) msg)

failAt :: ParserErrorCode -> Span -> Text -> Parser a
failAt code s msg = customFailure (Diagnostic code s msg)

-- Capture precisely the consumed source; layout delimiters have no synthetic
-- tokens, so their ranges come from the first and last real tokens.
located :: Parser a -> Parser (Located a)
located body = do
  before <- getInput
  n <- getOffset
  value <- body
  after <- getOffset
  ending <- asks fileEnd
  let first = case before of t : _ -> tokenSpan t; [] -> ending
      lastSpan = case drop (after - n - 1) before of
        t : _ | after > n -> tokenSpan t
        _ -> first
  pure (at (Span (sourceFile first) (start first) (end lastSpan)) value)

binary :: (Located a -> Located a -> a) -> Located a -> Located a -> Located a
binary constructor a b = at ((location a) {end = end (location b)}) (constructor a b)

unrestricted :: Parser a -> Parser a
unrestricted p = lookAhead (accept (const True)) *> local (\e -> e {floorColumn = 0, singleLine = Nothing}) p

atItem :: Parser a -> Parser a
atItem p = do
  mt <- peek
  case mt of
    Nothing -> p
    Just t -> local (\e -> e {itemLine = line (start (tokenSpan t)), itemColumn = column (start (tokenSpan t))}) p

nameFrom :: NameNotation -> Token -> Name
nameFrom notation t =
  Name
    (tokenSpan t)
    (SourceOrigin (tokenSpan t))
    (tokenText t)
    (if tokenKind t `elem` [Upper, PragmaName] || T.isPrefixOf ":" (tokenText t) then UpperName else LowerName)
    notation

lowerName, upperIdent, identifier, valueName, upperName, operatorName :: Parser Name
lowerName = nameFrom Alphabetic <$> kind Lower
upperIdent = nameFrom Alphabetic <$> kind Upper
identifier = lowerName <|> upperIdent
valueName = lowerName <|> try (namedOperator False)
upperName = upperIdent <|> try (namedOperator True)
operatorName = try (namedOperator False) <|> namedOperator True

namedOperator :: Bool -> Parser Name
namedOperator upper = do
  n <- located $ do
    void (text "(")
    t <- accept (\tok -> tokenKind tok == Symbol && T.isPrefixOf ":" (tokenText tok) == upper)
    void (text ")")
    pure t
  pure ((nameFrom ParenthesizedOperator (concrete n)) {nameLocation = location n, nameOrigin = origin n})

moduleParser :: Parser ([Pragma], [Import], [Declaration])
moduleParser = do
  ps <- many (atItem pragma)
  is <- many (atItem useDeclaration)
  ds <- many (atItem topDeclaration)
  dot <- nextIs "."
  when dot (failHere InvalidLayoutContinuation "dot cannot cross a layout boundary")
  eof
  pure (ps, is, ds)

pragma :: Parser Pragma
pragma = located $ do
  void (text "{-#")
  n <- nameFrom Alphabetic <$> kind PragmaName
  args <-
    many $
      located
        ( (IdentifierArgument <$> (identifier <|> try operatorName))
            <|> (StringArgument . tokenText <$> kind StringLiteral)
        )
  checkSeparated (nameLocation n) args
  void (text "#-}")
  pure (Pragma n args)
  where
    checkSeparated _ [] = pure ()
    checkSeparated previous (arg : rest) = do
      when
        (offset (start (location arg)) <= offset (end previous) + 1)
        (failAt InvalidPragmaArguments (location arg) "pragma arguments must be whitespace-separated")
      checkSeparated (location arg) rest

useDeclaration :: Parser Import
useDeclaration = located $ do
  void (text "use")
  ns <- upperIdent `sepBy1` text "."
  mode <- (text "as" *> (Aliased <$> upperIdent)) <|> selection <|> pure ModuleOnly
  trailingPub <- nextIs "pub"
  when
    (trailingPub && case mode of ModuleOnly -> True; Aliased _ -> True; _ -> False)
    (failHere InvalidImport "pub requires an explicit import list")
  pure (Import ns mode)
  where
    selection = do
      void (text "(")
      allMembers <- nextIs ".."
      items <- if allMembers then text ".." *> pure [] else importItem `sepBy1` text ","
      void (text ")")
      exported <- maybe False (const True) <$> optional (text "pub")
      pure (if allMembers then AllMembers exported else Selected items exported)
    importItem = located $ do
      n <- upperName <|> lowerName <|> operatorName
      members <-
        if nameSpace n == LowerName
          then pure Nothing
          else optional $ do
            void (text "(")
            m <-
              (text ".." *> pure AllConstructors)
                <|> (SelectedConstructors <$> ((identifier <|> operatorName) `sepBy1` text ","))
            void (text ")")
            pure m
      pure (ImportItem n members)

topDeclaration :: Parser Declaration
topDeclaration =
  typeDeclaration
    <|> traitDeclaration
    <|> implementation
    <|> located (PragmaDeclaration <$> pragma)
    <|> signature
    <|> topRecordDeclaration
    <|> alias
    <|> namedValue
    <|> invalidTopPattern
  where
    invalidTopPattern = do
      p <- optional (try (lookAhead patternParser))
      t <- text "("
      case p >>= infixHead of
        Just op -> failAt InvalidDeclarationHead (nameLocation op) "infix declaration head"
        Nothing -> case p of
          Just _ -> failAt InvalidDeclarationHead (tokenSpan t) "top-level binding name required"
          Nothing -> optional anyOperator *> failHere InvalidSyntax "invalid binding name"

-- Named record patterns are the explicit v1 exception to named top-level heads.
topRecordDeclaration :: Parser Declaration
topRecordDeclaration = do
  candidate <- lookAhead (try (patternParser <* text "="))
  when (not (recordHead candidate)) empty
  patternDeclaration
  where
    recordHead p = case concrete p of
      RecordP _ _ -> True
      ParenP q -> recordHead q
      AnnotatedP q _ -> recordHead q
      _ -> False

signature :: Parser Declaration
signature = do
  void (lookAhead (try ((valueName <|> upperName) <* text ":")))
  located $ do
    n <- valueName <|> upperName
    void (text ":")
    if nameSpace n == UpperName
      then KindSignature n <$> kindExpression
      else TypeSignature n <$> signatureType

signatureType :: Parser SignatureType
signatureType = located $ do
  qs <- many $ do
    q <- located $ unrestricted $ do
      void (text "{")
      n <- lowerName
      k <- optional (text ":" *> kindExpression)
      void (text "}")
      pure (Quantifier n k)
    void (text "->")
    pure q
  SignatureType qs <$> typeExpression

alias :: Parser Declaration
alias = located $ do
  n <- upperName
  ps <- many typeParameter
  void (text "=")
  TypeAlias n ps <$> typeExpression

typeParameter :: Parser TypeParameter
typeParameter =
  located $
    (\n -> TypeParameter n Nothing)
      <$> lowerName
        <|> unrestricted
          ( do
              void (text "(")
              n <- lowerName
              void (text ":")
              k <- kindExpression
              void (text ")")
              pure (TypeParameter n (Just k))
          )

typeBinder :: Parser TypeBinder
typeBinder = located $ do
  void (text "@")
  ((\n -> TypeBinder n Nothing) <$> lowerName)
    <|> unrestricted
      ( do
          void (text "(")
          n <- lowerName
          void (text ":")
          k <- kindExpression
          void (text ")")
          pure (TypeBinder n (Just k))
      )

namedValue :: Parser Declaration
namedValue = located $ do
  n <- valueName
  bs <- many typeBinder
  ps <- many binderPattern
  intro <- text "="
  body <- introducedExpression intro
  wh <- optional whereClause
  pure (FunctionClause n bs ps body wh)

whereClause :: Parser WhereClause
whereClause = located $ do
  intro <- text "where"
  WhereClause <$> block False False intro localDeclaration

localDeclaration :: Parser Declaration
localDeclaration = signature <|> tryNamed <|> patternDeclaration
  where
    tryNamed = do
      void (lookAhead (try (valueName *> many typeBinder *> many binderPattern *> text "=")))
      namedValue

patternDeclaration :: Parser Declaration
patternDeclaration = do
  void (lookAhead (try (patternParser <* text "=")))
  located $ do
    pat <- patternParser
    rejectInfixHead pat
    intro <- text "="
    PatternBinding pat <$> introducedExpression intro <*> optional whereClause

infixHead :: Pattern -> Maybe Name
infixHead n = case concrete n of
  OpAppP _ op _ -> Just op
  ParenP p -> infixHead p
  AnnotatedP p _ -> infixHead p
  _ -> Nothing

rejectInfixHead :: Pattern -> Parser ()
rejectInfixHead = maybe (pure ()) (\op -> failAt InvalidDeclarationHead (nameLocation op) "infix declaration head") . infixHead

typeDeclaration :: Parser Declaration
typeDeclaration = located $ do
  void (text "type")
  n <- upperName
  ps <- many typeParameter
  intro <- text "="
  -- Select the body category once; later items cannot switch categories.
  body <- block True True intro (fieldMember <|> constructorMember)
  typedBody <- case blockItems body of
    Left _ : _ -> Fields <$> traverseBlock fieldOnly body
    _ -> Constructors <$> traverseBlock constructorOnly body
  pure (DataDeclaration n ps typedBody)
  where
    fieldMember = do
      void (lookAhead (try (identifier <* text ":") <|> lowerName))
      Left
        <$> located
          ( do
              n <- identifier
              colon <- nextIs ":"
              when (not colon) (failAt InvalidDeclarationHead (nameLocation n) "constructor name or field signature required")
              void (text ":")
              FieldSignature n <$> typeExpression
          )
    constructorMember = Right <$> located (Constructor <$> upperName <*> many typeAtom)
    fieldOnly (Left f) = pure f
    fieldOnly (Right c) = case concrete c of Constructor n _ -> failAt MixedTypeBody (nameLocation n) "mixed type body"
    constructorOnly (Right c) = pure c
    constructorOnly (Left f) = case concrete f of FieldSignature n _ -> failAt MixedTypeBody (nameLocation n) "mixed type body"

traverseBlock :: (a -> Parser b) -> Block a -> Parser (Block b)
traverseBlock f b = Block (blockLocation b) (blockOrigin b) (blockDelimiter b) <$> traverse f (blockItems b)

traitDeclaration :: Parser Declaration
traitDeclaration = located $ do
  void (text "trait")
  ctx <- optionalContext
  n <- upperIdent
  p <- typeParameter
  intro <- text "="
  TraitDeclaration ctx n p <$> block True True intro signature

implementation :: Parser Declaration
implementation = located $ do
  void (text "impl")
  ctx <- optionalContext
  ref <- constraint
  intro <- text "="
  Implementation ctx ref <$> block True True intro namedValue

optionalContext :: Parser [Constraint]
optionalContext = maybe [] id <$> optional (try (constraints <* text "=>"))

constraints :: Parser [Constraint]
constraints = (pure <$> constraint) <|> unrestricted (text "(" *> (constraint `sepBy1` text ",") <* text ")")

constraint :: Parser Constraint
constraint = located (Constraint <$> upperIdent <*> typeAtom)

kindExpression :: Parser KindExpr
kindExpression = rightArrow ArrowK kindAtom
  where
    kindAtom =
      located (DottedK <$> qualifiedUpper)
        <|> located (IdentK <$> (upperName <|> lowerName))
        <|> located (ParenK <$> unrestricted (text "(" *> kindExpression <* text ")"))

typeExpression :: Parser TypeExpr
typeExpression = do
  ctx <- optionalContext
  ty <- rightArrow ArrowT productType
  case ctx of
    [] -> pure ty
    c : _ -> pure (at ((location c) {end = end (location ty)}) (ConstrainedT ctx ty))
  where
    productType = do
      first <- typeOperators
      rest <- optional (text "*" *> productType)
      pure (maybe first (binary ProductT first) rest)
    typeOperators = operators OpAppT upperOperator (applicationOf AppT typeAtom)

rightArrow :: (Located a -> Located a -> a) -> Parser (Located a) -> Parser (Located a)
rightArrow constructor p = do
  a <- p
  b <- optional (text "->" *> rightArrow constructor p)
  pure (maybe a (binary constructor a) b)

applicationOf :: (Located a -> Located a -> a) -> Parser (Located a) -> Parser (Located a)
applicationOf constructor p = do
  a <- p
  bs <- many p
  pure (foldl (binary constructor) a bs)

typeAtom :: Parser TypeExpr
typeAtom =
  located (DottedT <$> qualifiedUpper)
    <|> located (IdentT <$> (upperName <|> lowerName))
    <|> listType
    <|> parenType
  where
    listType = located $ unrestricted $ do
      void (text "[")
      ty <- optional typeExpression
      void (text "]")
      pure (maybe ListConstructor ListT ty)
    parenType =
      try (located (text "(" *> text "*" *> text ")" *> pure ProductConstructor))
        <|> try (located (text "(" *> text "->" *> text ")" *> pure FunctionConstructor))
        <|> located (ParenT <$> unrestricted (text "(" *> typeExpression <* text ")"))

qualifiedUpper :: Parser [Name]
qualifiedUpper = do
  void (lookAhead (try (upperIdent *> text ".")))
  a <- upperIdent
  void (text ".")
  rest <- qualifiedTail
  pure (a : rest)
  where
    qualifiedTail = do
      n <- upperName
      dot <- nextIs "."
      if dot
        then do
          when (nameNotation n /= Alphabetic) (failHere InvalidModuleName "module components must be uppercase identifiers")
          void (text ".")
          (n :) <$> qualifiedTail
        else pure [n]

expression :: Parser Expr
expression = do
  body <- unannotatedExpression
  annotation <- optional $ try $ do
    void (text ":")
    ty <- typeExpression
    -- Bare arrows remain clause/lambda delimiters. A function or qualified
    -- type must be parenthesized here, or the whole annotation delimited.
    case concrete ty of
      ArrowT {} -> empty
      ConstrainedT {} -> empty
      _ -> pure ty
  pure $ case annotation of
    Nothing -> body
    Just ty -> at ((location body) {end = end (location ty)}) (Annotated body ty)

unannotatedExpression :: Parser Expr
unannotatedExpression = lambda <|> nonLambda

lambda :: Parser Expr
lambda = do
  void (lookAhead (try (many typeBinder *> many binderPattern *> text "->")))
  located $ do
    bs <- many typeBinder
    ps <- many binderPattern
    when (null bs && null ps) (failHere MissingBinder "lambda binder required")
    intro <- text "->"
    Lam bs ps <$> introducedExpression intro

nonLambda :: Parser Expr
nonLambda =
  ifExpression
    <|> matchExpression
    <|> doExpression
    <|> explicitExpressionBlock
    <|> operators OpApp anyOperator prefixExpression

introducedExpression :: Token -> Parser Expr
introducedExpression intro = do
  mt <- peek
  base <- asks itemColumn
  let ln = line (end (tokenSpan intro))
  case mt of
    Just t | tokenText t == "{" -> local (\e -> e {floorColumn = 0, singleLine = Nothing}) expression
    Just t
      | line (start (tokenSpan t)) > ln ->
          if column (start (tokenSpan t)) <= base
            then failHere InsufficientIndentation "expression must be indented"
            else expressionBlock t
    _ -> expression

ifExpression :: Parser Expr
ifExpression = located $ do
  intro <- text "if"
  If
    <$> block
      False
      False
      intro
      ( located $ do
          cond <- nonLambda
          arrow <- text "->"
          IfClause cond <$> introducedExpression arrow
      )

matchExpression :: Parser Expr
matchExpression = located $ do
  intro <- text "with"
  let introLine = line (start (tokenSpan intro))
  scrutinee <- local (\e -> e {singleLine = Just introLine}) expression
  b <- block True False intro $ located $ do
    p <- patternParser
    g <- optional (text "if" *> nonLambda)
    arrow <- text "->"
    MatchClause p g <$> introducedExpression arrow
  pure (With scrutinee b)

doExpression :: Parser Expr
doExpression = located $ do
  intro <- text "do"
  Do <$> block False False intro doStatement
  where
    doStatement = doBind <|> located (DoDeclaration <$> localValue) <|> located (DoExpression <$> doItemExpression)
    localValue =
      ( do
          void (lookAhead (try (valueName *> many typeBinder *> many binderPattern *> text "=")))
          namedValue
      )
        <|> patternDeclaration
    doItemExpression = do
      signatureHead <- optional (try (lookAhead ((valueName <|> upperName) <* text ":")))
      case signatureHead of
        Just _ -> do
          void (valueName <|> upperName)
          failHere InvalidSyntax "signatures are not permitted in do blocks; parenthesize an expression annotation"
        Nothing -> expression
    doBind = do
      void (lookAhead (try (patternParser <* text "<-")))
      located $ do
        p <- patternParser
        arrow <- text "<-"
        PatternBind p <$> introducedExpression arrow

explicitExpressionBlock :: Parser Expr
explicitExpressionBlock = lookAhead (text "{") >>= expressionBlock

expressionBlock :: Token -> Parser Expr
expressionBlock intro = located $ do
  b <- block False True intro (located (LocalDeclaration <$> localDeclaration) <|> located (Expression <$> expression))
  case reverse (blockItems b) of
    n : _ -> case concrete n of
      Expression _ -> pure (ExprBlock b)
      LocalDeclaration _ -> failAt MissingFinalExpression (closingSpan b) "expression block must end in an expression"
    [] -> failHere EmptyBlock "nonempty expression block required"
  where
    closingSpan b = let s = blockLocation b in s {start = end s}

prefixExpression :: Parser Expr
prefixExpression = located (text "-" *> (Negate <$> prefixExpression)) <|> termApplication

termApplication :: Parser Expr
termApplication = do
  f <- postfix
  ts <- many (located (text "@" *> (TypeArgument <$> typeAtom)))
  let static = case reverse ts of
        t : _ -> at ((location f) {end = end (location t)}) (StaticApp f ts)
        [] -> f
  xs <- many postfix
  pure (foldl (binary App) static xs)

postfix :: Parser Expr
postfix = atom >>= suffixes
  where
    suffixes a =
      ( do
          void (text ".")
          b <- identifier <|> (when (not (modulePrefix a)) empty *> operatorName)
          let s = (location a) {end = end (nameLocation b)}
          suffixes (at s (case concrete a of Dotted base ns -> Dotted base (ns ++ [b]); _ -> Dotted a [b]))
      )
        <|> ( do
                intro <- text "with"
                b <- block False False intro recordField
                suffixes (at ((location a) {end = end (blockLocation b)}) (RecordWith a b))
            )
        <|> pure a
    recordField = located $ do
      n <- identifier
      intro <- text "="
      if nameSpace n == UpperName
        then TypeField n <$> typeExpression
        else Field n <$> introducedExpression intro <*> optional whereClause
    modulePrefix a = case concrete a of
      Ident n -> upperComponent n
      Dotted base ns -> modulePrefix base && all upperComponent ns
      _ -> False
    upperComponent n = nameSpace n == UpperName && nameNotation n == Alphabetic

atom :: Parser Expr
atom =
  located (Ident <$> identifier)
    <|> located (Lit <$> literal)
    <|> located (Ident <$> try operatorName)
    <|> located (List <$> unrestricted (text "[" *> (expression `sepBy` text ",") <* text "]"))
    <|> parentheses unannotatedExpression typeExpression Unit Product Paren Annotated

literal :: Parser Literal
literal = do
  t <- accept (\tok -> tokenKind tok `elem` [NumberLiteral, CharacterLiteral, StringLiteral])
  pure
    ( case tokenKind t of
        NumberLiteral -> if T.any (== '.') (tokenText t) then FloatLiteral (tokenText t) else IntegerLiteral (tokenText t)
        CharacterLiteral -> CharLiteral (tokenText t)
        _ -> StringLiteralText (tokenText t)
    )

parentheses ::
  Parser (Located a) ->
  Parser TypeExpr ->
  a ->
  ([Located a] -> a) ->
  (Located a -> a) ->
  (Located a -> TypeExpr -> a) ->
  Parser (Located a)
parentheses inside annotation unit productNode paren annotated = located $ unrestricted $ do
  void (text "(")
  closed <- nextIs ")"
  if closed
    then text ")" *> pure unit
    else do
      a <- inside
      comma <- nextIs ","
      if comma
        then do
          void (text ",")
          bs <- inside `sepBy1` text ","
          void (text ")")
          pure (productNode (a : bs))
        else do
          ty <- optional (text ":" *> annotation)
          void (text ")")
          pure (maybe (paren a) (annotated a) ty)

binderPattern :: Parser Pattern
binderPattern =
  located (IdentP <$> lowerName)
    <|> located (LitP <$> literal)
    <|> negativePattern
    <|> located (IdentP <$> upperIdent)
    <|> patternList
    <|> parentheses patternParser typeExpression UnitP ProductP ParenP AnnotatedP

patternParser :: Parser Pattern
patternParser = operators OpAppP upperOperator simplePattern
  where
    simplePattern =
      located (IdentP <$> lowerName)
        <|> located (LitP <$> literal)
        <|> negativePattern
        <|> recordPattern
        <|> constructor
        <|> patternList
        <|> parentheses patternParser typeExpression UnitP ProductP ParenP AnnotatedP
    constructor = do
      a <- located (DottedP <$> qualifiedUpper) <|> located (IdentP <$> upperName)
      bs <- many binderPattern
      pure
        ( case reverse bs of
            b : _ -> at ((location a) {end = end (location b)}) (ConstructorP a bs)
            [] -> a
        )

recordPattern :: Parser Pattern
recordPattern = do
  void (lookAhead (try (constructorName *> text "with")))
  located $ do
    receiver <- constructorName
    intro <- text "with"
    -- A record pattern is self-delimiting; construction alone admits layout.
    void (lookAhead (text "{"))
    fields <- block True False intro $ located $ do
      n <- identifier
      void (text "=")
      PatternField n <$> patternParser
    pure (RecordP receiver fields)
  where
    constructorName = located (DottedP <$> qualifiedUpper) <|> located (IdentP <$> upperName)

negativePattern :: Parser Pattern
negativePattern = located $ do
  void (text "-")
  t <- kind NumberLiteral
  let s = tokenSpan t
      lit = if T.any (== '.') (tokenText t) then FloatLiteral (tokenText t) else IntegerLiteral (tokenText t)
  pure (NegateP (at s (LitP lit)))

patternList :: Parser Pattern
patternList = located (ListP <$> unrestricted (text "[" *> (patternParser `sepBy` text ",") <* text "]"))

anyOperator, upperOperator :: Parser Name
anyOperator = nameFrom BareOperator <$> kind Symbol
upperOperator = nameFrom BareOperator <$> accept (\t -> tokenKind t == Symbol && T.isPrefixOf ":" (tokenText t))

precedence :: Name -> Int
precedence op = case T.uncons (nameText op) of
  Just (c, _)
    | c `elem` ("*/%" :: String) -> 8
    | c `elem` ("+-" :: String) -> 7
    | c == ':' -> 6
    | c `elem` ("<>" :: String) -> 5
    | c `elem` ("=!" :: String) -> 4
    | c == '&' -> 3
    | c == '^' -> 2
    | c == '|' -> 1
  _ -> 9

rightAssociative :: Name -> Bool
rightAssociative = T.isSuffixOf ":" . nameText

-- Group encountered spellings using the same algorithm in all three categories.
operators :: (Located a -> Name -> Located a -> a) -> Parser Name -> Parser (Located a) -> Parser (Located a)
operators constructor op operand = do
  first <- operand
  pairs <- many ((,) <$> op <*> operand)
  group first pairs
  where
    build a operator b = at ((location a) {end = end (location b)}) (constructor a operator b)
    group a [] = pure a
    group a pairs = do
      let lowest = minimum (map (precedence . fst) pairs)
          same = filter ((== lowest) . precedence . fst) pairs
      case same of
        (firstOp, _) : rest -> case filter ((/= rightAssociative firstOp) . rightAssociative . fst) rest of
          (bad, _) : _ -> failAt MixedAssociativity (nameLocation bad) "mixed associativity in one precedence group"
          [] -> assemble lowest (rightAssociative firstOp) a pairs
        [] -> pure a
    assemble level right a pairs = do
      let (higher, remainder) = break ((== level) . precedence . fst) pairs
      left <- group a higher
      case remainder of
        [] -> pure left
        (operator, rhs) : rest ->
          if right
            then build left operator <$> group rhs rest
            else do
              let (nextHigher, following) = break ((== level) . precedence . fst) rest
              r <- group rhs nextHigher
              assemble level right (build left operator r) following

-- Layout begins only when a grammar production calls this function. Braces
-- disable outer layout and require separators even across physical newlines.
block :: Bool -> Bool -> Token -> Parser a -> Parser (Block a)
block allowEmpty allowInline intro item = do
  explicit <- nextIs "{"
  if explicit
    then do
      n <- local (\e -> e {floorColumn = 0, singleLine = Nothing}) $ located $ unrestricted $ do
        void (text "{")
        done <- nextIs "}"
        when (done && not allowEmpty) (failHere EmptyBlock "nonempty block required")
        ns <- if done then pure [] else explicitItems
        void (text "}")
        pure ns
      pure (Block (location n) (origin n) Explicit (concrete n))
    else do
      mt <- peek
      base <- asks itemColumn
      case mt of
        Nothing -> failHere ExpectedBlock "block required"
        Just t -> do
          let p = start (tokenSpan t)
              later = line p > line (start (tokenSpan intro))
          when (not later && not allowInline) (failHere ExpectedBlock "expected braces or a newline before block")
          when (later && column p <= base) (failHere InsufficientIndentation "block must be indented")
          n <- located (local (\e -> e {floorColumn = column p, singleLine = Nothing}) (layoutItems (column p)))
          pure (Block (location n) (origin n) Layout (concrete n))
  where
    explicitItems = do
      n <- atItem item
      semi <- optional (text ";")
      case semi of
        Nothing -> pure [n]
        Just _ -> do
          closed <- nextIs "}"
          if closed then pure [n] else (n :) <$> explicitItems
    layoutItems indent = do
      n <- atItem item
      mt <- peek
      case mt of
        Just t | column (start (tokenSpan t)) == indent && tokenText t `notElem` ["}", ")", "]", ";"] -> do
          when (tokenText t == ".") (failHere InvalidLayoutContinuation "dot cannot begin a layout item")
          (n :) <$> layoutItems indent
        _ -> pure [n]

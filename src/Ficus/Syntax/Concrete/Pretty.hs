-- | A deliberately simple AST printer. Blocks retain their source delimiters,
-- with four spaces per nesting level independent of the opening column.
-- Comments are retained in source order above their containing top-level item.
-- Use 'renderSource' instead when exact original text/placement is required.
module Ficus.Syntax.Concrete.Pretty
  ( prettyModule,
    prettyExpr,
    prettyDeclaration,
  )
where

import Data.List (intersperse)
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Syntax.Concrete
import Text.PrettyPrint qualified as P

-- Unlike column-aligned document concatenation, nesting here changes only the
-- indentation of new lines. Thus "f = if {" does not add eight extra spaces to
-- the clauses merely because the opening brace occurs later on that line.
data Piece = Chunk Text | Newline | Indented [Piece]

type Doc = [Piece]

chunk :: Text -> Doc
chunk t = [Chunk t]

joinDocs :: Doc -> [Doc] -> Doc
joinDocs separator = concat . intersperse separator

spaces :: [Doc] -> Doc
spaces = foldr append [] . filter (not . null)
  where
    append doc [] = doc
    append doc rest
      | startsOnNewline rest = doc ++ rest
      | otherwise = doc ++ chunk " " ++ rest
    startsOnNewline (Newline : _) = True
    startsOnNewline (Indented nested : _) = startsOnNewline nested
    startsOnNewline _ = False

parens :: Doc -> Doc
parens d = chunk "(" ++ d ++ chunk ")"

commas :: [Doc] -> Doc
commas = joinDocs (chunk ", ")

-- Assemble each logical line before nesting it, so Hughes-PJ's horizontal
-- concatenation cannot align subsequent block lines under an opening brace.
data Lines = Lines
  {finishedLines :: [P.Doc], currentLine :: [P.Doc], lineIndent :: Int}

render :: Doc -> Text
render doc = T.pack (P.render (foldr (P.$+$) P.empty (reverse (finishedLines final))))
  where
    final = finish (renderAt 0 (Lines [] [] 0) doc)
    renderAt indentation = foldl' (step indentation)
    step indentation linesSoFar = \case
      Chunk t
        | T.null t -> linesSoFar
        | otherwise ->
            linesSoFar
              { currentLine = P.text (T.unpack t) : currentLine linesSoFar,
                lineIndent = if null (currentLine linesSoFar) then indentation else lineIndent linesSoFar
              }
      Newline -> finish linesSoFar
      Indented nested -> renderAt (indentation + 4) linesSoFar nested
    finish linesSoFar
      | null (currentLine linesSoFar) = linesSoFar
      | otherwise =
          Lines
            (P.nest (lineIndent linesSoFar) (P.hcat (reverse (currentLine linesSoFar))) : finishedLines linesSoFar)
            []
            0

prettyModule :: ConcreteModule -> Text
prettyModule m = T.concat (items True (moduleComments m) declarations)
  where
    declarations =
      [(location p, pragma p, False) | p <- modulePragmas m]
        ++ [(location i, importDoc i, False) | i <- moduleImports m]
        ++ [ (location d, declaration d, key == Nothing || key /= previous)
           | (previous, d) <- zip (Nothing : map declarationKey (moduleDeclarations m)) (moduleDeclarations m),
             let key = declarationKey d
           ]
    declarationKey d = do
      n <- case concrete d of
        TypeSignature n _ -> Just n
        KindSignature n _ -> Just n
        FunctionClause n _ _ _ _ -> Just n
        TypeAlias n _ _ -> Just n
        DataDeclaration n _ _ -> Just n
        TraitDeclaration _ n _ _ -> Just n
        _ -> Nothing
      if nameText n == "_" then Nothing else Just (nameSpace n, nameText n)
    items _ cs [] = map comment cs
    items first cs ((s, doc, separate) : rest) =
      let (before, after) = span ((<= offset (end s)) . offset . start . commentSpan) cs
          spacing = if separate && not first then ["\n"] else []
       in spacing ++ map comment before ++ [render doc <> "\n"] ++ items False after rest
    comment c = commentText c <> "\n"

prettyExpr :: Expr -> Text
prettyExpr = render . expr

prettyDeclaration :: Declaration -> Text
prettyDeclaration = render . declaration

name :: Name -> Doc
name n = case nameNotation n of
  ParenthesizedOperator -> parens (chunk (nameText n))
  Alphabetic -> chunk (nameText n)
  BareOperator -> chunk (nameText n)

literal :: Literal -> Doc
literal =
  chunk . \case
    IntegerLiteral t -> t
    FloatLiteral t -> t
    CharLiteral t -> t
    StringLiteralText t -> t

block :: (a -> Doc) -> Block a -> Doc
block f b = case blockDelimiter b of
  Layout -> [Newline, Indented (joinDocs [Newline] (map f (blockItems b)))]
  Explicit -> case blockItems b of
    [] -> chunk "{}"
    xs -> chunk "{" ++ [Newline, Indented (concatMap (\x -> f x ++ chunk ";" ++ [Newline]) xs)] ++ chunk "}"

expr :: Expr -> Doc
expr e = case concrete e of
  Ident n -> name n
  Lit l -> literal l
  App f x -> spaces [expr f, expr x]
  StaticApp f args -> spaces (expr f : map argument args)
  OpApp a op b -> spaces [expr a, chunk (nameText op), expr b]
  Negate x -> spaces [chunk "-", expr x]
  Lam bs ps body -> spaces (map binder bs ++ map patternDoc ps ++ [chunk "->", expr body])
  If b -> spaces [chunk "if", block ifClause b]
  With x b ->
    let scrutinee = expr x
     in if endsInLayout scrutinee
          then spaces [chunk "with", [Indented scrutinee], [Newline] ++ block matchClause b]
          else spaces [chunk "with", scrutinee, block matchClause b]
  Do b -> spaces [chunk "do", block doStatement b]
  ExprBlock b -> block blockItem b
  RecordWith x b -> spaces [expr x, chunk "with", block field b]
  Dotted x ns -> expr x ++ concatMap (\n -> chunk "." ++ name n) ns
  Paren x -> parens (expr x)
  Annotated x t -> parens (spaces [expr x, chunk ":", typeDoc t])
  Unit -> chunk "()"
  Product xs -> parens (commas (map expr xs))
  List xs -> chunk "[" ++ commas (map expr xs) ++ chunk "]"

-- A following block must dedent past a layout block in the scrutinee.
endsInLayout :: Doc -> Bool
endsInLayout doc = case reverse doc of
  Indented _ : _ -> True
  _ -> False

patternDoc :: Pattern -> Doc
patternDoc p = case concrete p of
  IdentP n -> name n
  LitP l -> literal l
  NegateP x -> spaces [chunk "-", patternDoc x]
  ConstructorP c ps -> spaces (patternDoc c : map patternDoc ps)
  RecordP c fields -> spaces [patternDoc c, chunk "with", block patternField fields]
  OpAppP a op b -> spaces [patternDoc a, chunk (nameText op), patternDoc b]
  ParenP x -> parens (patternDoc x)
  AnnotatedP x t -> parens (spaces [patternDoc x, chunk ":", typeDoc t])
  UnitP -> chunk "()"
  ProductP ps -> parens (commas (map patternDoc ps))
  ListP ps -> chunk "[" ++ commas (map patternDoc ps) ++ chunk "]"
  DottedP ns -> dottedNames ns

patternField :: PatternField -> Doc
patternField f = case concrete f of PatternField n p -> spaces [name n, chunk "=", patternDoc p]

typeDoc :: TypeExpr -> Doc
typeDoc t = case concrete t of
  IdentT n -> name n
  DottedT ns -> dottedNames ns
  AppT f x -> spaces [typeDoc f, typeDoc x]
  OpAppT a op b -> spaces [typeDoc a, chunk (nameText op), typeDoc b]
  ArrowT a b -> spaces [typeDoc a, chunk "->", typeDoc b]
  LazyArrowT a b -> spaces [typeDoc a, chunk "~>", typeDoc b]
  ProductT a b -> spaces [typeDoc a, chunk "*", typeDoc b]
  ConstrainedT cs x -> spaces [context cs, typeDoc x]
  ParenT x -> parens (typeDoc x)
  ListT x -> chunk "[" ++ typeDoc x ++ chunk "]"
  ListConstructor -> chunk "[]"
  ProductConstructor -> chunk "(*)"
  FunctionConstructor -> chunk "(->)"
  LazyFunctionConstructor -> chunk "(~>)"

kindDoc :: KindExpr -> Doc
kindDoc k = case concrete k of
  IdentK n -> name n
  DottedK ns -> dottedNames ns
  ArrowK a b -> spaces [kindDoc a, chunk "->", kindDoc b]
  ParenK x -> parens (kindDoc x)

dottedNames :: [Name] -> Doc
dottedNames = joinDocs (chunk ".") . map name

parameterDoc :: Name -> Maybe KindExpr -> Doc
parameterDoc n = maybe (name n) (\k -> parens (spaces [name n, chunk ":", kindDoc k]))

parameter :: TypeParameter -> Doc
parameter p = case concrete p of TypeParameter n k -> parameterDoc n k

binder :: TypeBinder -> Doc
binder b = case concrete b of TypeBinder n k -> chunk "@" ++ parameterDoc n k

argument :: TypeArgument -> Doc
argument a = case concrete a of TypeArgument t -> chunk "@" ++ typeDoc t

quantifier :: Quantifier -> Doc
quantifier q = case concrete q of
  Quantifier n k -> chunk "{" ++ spaces [name n, maybe [] (\t -> spaces [chunk ":", kindDoc t]) k] ++ chunk "}"

constraint :: Constraint -> Doc
constraint c = case concrete c of Constraint n t -> spaces [name n, typeDoc t]

context :: [Constraint] -> Doc
context = \case
  [] -> []
  [c] -> spaces [constraint c, chunk "=>"]
  cs -> spaces [parens (commas (map constraint cs)), chunk "=>"]

declaration :: Declaration -> Doc
declaration d = case concrete d of
  TypeSignature n t -> spaces [name n, chunk ":", signature t]
  KindSignature n k -> spaces [name n, chunk ":", kindDoc k]
  FunctionClause n bs ps body wh ->
    spaces (name n : map binder bs ++ map patternDoc ps ++ [chunk "=", scopedBody body wh])
  PatternBinding p body wh -> spaces [patternDoc p, chunk "=", scopedBody body wh]
  TypeAlias n ps t -> spaces (name n : map parameter ps ++ [chunk "=", typeDoc t])
  DataDeclaration n ps body -> spaces (chunk "type" : name n : map parameter ps ++ [chunk "=", typeBody body])
  TraitDeclaration cs n p b -> spaces [chunk "trait", context cs, name n, parameter p, chunk "=", block declaration b]
  Implementation cs c b -> spaces [chunk "impl", context cs, constraint c, chunk "=", block declaration b]
  PragmaDeclaration p -> pragma p

signature :: SignatureType -> Doc
signature t = case concrete t of
  SignatureType qs x -> spaces (concatMap (\q -> [quantifier q, chunk "->"]) qs ++ [typeDoc x])

typeBody :: TypeBody -> Doc
typeBody = \case
  Constructors b -> block constructor b
  Fields b -> block fieldSignature b
  where
    constructor c = case concrete c of Constructor n ts -> spaces (name n : map typeDoc ts)
    fieldSignature f = case concrete f of FieldSignature n t -> spaces [name n, chunk ":", typeDoc t]

whereDoc :: Maybe WhereClause -> Doc
whereDoc = maybe [] (\w -> case concrete w of WhereClause b -> spaces [chunk "where", block declaration b])

-- Reserve a continuation indentation for where, so it cannot attach to the
-- final declaration inside the preceding layout block.
scopedBody :: Expr -> Maybe WhereClause -> Doc
scopedBody body wh =
  let rhs = expr body
   in case wh of
        Just _ | endsInLayout rhs -> [Indented (rhs ++ [Newline] ++ whereDoc wh)]
        _ -> spaces [rhs, whereDoc wh]

field :: Field -> Doc
field f = case concrete f of
  Field n e wh -> spaces [name n, chunk "=", scopedBody e wh]
  TypeField n t -> spaces [name n, chunk "=", typeDoc t]

ifClause :: IfClause -> Doc
ifClause c = case concrete c of IfClause condition body -> spaces [expr condition, chunk "->", expr body]

matchClause :: MatchClause -> Doc
matchClause c = case concrete c of
  MatchClause p guard body -> spaces [patternDoc p, maybe [] (\g -> spaces [chunk "if", expr g]) guard, chunk "->", expr body]

blockItem :: BlockItem -> Doc
blockItem i = case concrete i of LocalDeclaration d -> declaration d; Expression e -> expr e

doStatement :: DoStatement -> Doc
doStatement s = case concrete s of
  PatternBind p e -> spaces [patternDoc p, chunk "<-", expr e]
  DoDeclaration d -> declaration d
  DoExpression e -> expr e

pragma :: Pragma -> Doc
pragma p = case concrete p of
  Pragma n args -> spaces (chunk "{-#" : name n : map pragmaArgument args ++ [chunk "#-}"])
  where
    pragmaArgument a = case concrete a of IdentifierArgument n -> name n; QualifiedIdentifierArgument n ns -> dottedNames (n : ns); StringArgument t -> chunk t

importDoc :: Import -> Doc
importDoc i = case concrete i of
  Import ns mode -> spaces [chunk "use", dottedNames ns, importMode mode]
  where
    importMode = \case
      ModuleOnly -> []
      Aliased n -> spaces [chunk "as", name n]
      Selected xs exported -> spaces [parens (commas (map importItem xs)), if exported then chunk "pub" else []]
      AllMembers exported -> spaces [chunk "(..)", if exported then chunk "pub" else []]
    importItem item = case concrete item of
      ImportItem n members -> name n ++ maybe [] selection members
    selection = \case
      AllConstructors -> chunk "(..)"
      SelectedConstructors ns -> parens (commas (map name ns))

module Ficus.Parser.PrettySpec (tests, assertRoundTrip, roundTrip, idempotent) where

import Data.Text (Text)
import Ficus.Syntax.Concrete
import Ficus.Syntax.Concrete.Pretty
import Ficus.Syntax.Parser (parseModule)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

assertRoundTrip :: ConcreteModule -> Assertion
assertRoundTrip original = case parseModule "Pretty.ficus" output of
  Left d -> assertFailure (show d <> "\nFormatted source:\n" <> show output)
  Right formatted -> do
    validateConcrete formatted @?= Right ()
    normalize formatted @?= normalize original
    prettyModule formatted @?= output
  where
    output = prettyModule original

roundTrip :: Text -> Property
roundTrip source = case parseModule "Pretty.ficus" source of
  Left d -> counterexample (show d) False
  Right original -> case parseModule "Pretty.ficus" (prettyModule original) of
    Left d -> counterexample (show d <> "\n" <> show (prettyModule original)) False
    Right formatted -> normalize formatted === normalize original

idempotent :: Text -> Property
idempotent source = case parseModule "Pretty.ficus" source of
  Left d -> counterexample (show d) False
  Right original -> case parseModule "Pretty.ficus" (prettyModule original) of
    Left d -> counterexample (show d) False
    Right formatted -> prettyModule formatted === prettyModule original

tests :: TestTree
tests =
  testGroup
    "Concrete pretty printer"
    [ testCase "blank lines separate declarations and keep their comments attached" $
        parsed "use Foo\nuse Bar\na = 1\n-- next declaration\nb = 2\n" $ \m -> do
          prettyModule m @?= "use Foo\nuse Bar\n\na = 1\n\n-- next declaration\nb = 2\n"
          assertRoundTrip m,
      testGroup
        "adjacent declarations with the same name stay together"
        [ testCase title $ parsed source $ \m -> do
            prettyModule m @?= expected
            assertRoundTrip m
        | (title, source, expected) <-
            [ ( "signature and clause without moving later clauses",
                "foo : Int -> Int\nfoo 0 = 0\nbar x = x\nfoo x = x - 1\n",
                "foo : Int -> Int\nfoo 0 = 0\n\nbar x = x\n\nfoo x = x - 1\n"
              ),
              ( "multiple clauses",
                "foo 0 = 0\n\nfoo x = x\nbar = 1\n",
                "foo 0 = 0\nfoo x = x\n\nbar = 1\n"
              ),
              ( "operator signature and clauses",
                "(++) : Int -> Int -> Int\n(++) x y = x\n(++) x y = y\n",
                "(++) : Int -> Int -> Int\n(++) x y = x\n(++) x y = y\n"
              ),
              ( "kind signature and type alias",
                "Thing : Type\nThing = Int\nother = 1\n",
                "Thing : Type\nThing = Int\n\nother = 1\n"
              ),
              ( "comments between signature and clause",
                "foo : Int\n-- definition\nfoo = 1\n-- another name\nbar = 2\n",
                "foo : Int\n-- definition\nfoo = 1\n\n-- another name\nbar = 2\n"
              ),
              ( "wildcards have no shared name",
                "_ = 1\n_ = 2\n",
                "_ = 1\n\n_ = 2\n"
              )
            ]
        ],
      testGroup
        "block delimiters follow the source"
        [ testCase title $ parsed source $ \m -> do
            prettyModule m @?= expected
            assertRoundTrip m
        | (title, source, expected) <-
            [ ( "explicit braces",
                "f = { x = if { True -> 1; _ -> 0 }; x }",
                "f = {\n    x = if {\n        True -> 1;\n        _ -> 0;\n    };\n    x;\n}\n"
              ),
              ( "layout",
                "f =\n  x = if\n    True -> 1\n    _ -> 0\n  x",
                "f =\n    x = if\n        True -> 1\n        _ -> 0\n    x\n"
              ),
              ( "layout inside braces",
                "f = {\n  x = if\n    True -> 1\n    _ -> 0\n; x }",
                "f = {\n    x = if\n        True -> 1\n        _ -> 0;\n    x;\n}\n"
              ),
              ( "braces inside layout",
                "f =\n  x = if { True -> 1; _ -> 0 }\n  x",
                "f =\n    x = if {\n        True -> 1;\n        _ -> 0;\n    }\n    x\n"
              ),
              ( "empty explicit block",
                "trait Empty a = {}",
                "trait Empty a = {}\n"
              )
            ]
        ],
      testCase "where after layout stays attached to its owning declaration" $
        parsed "f = do\n    local = 1\n  where { other = 2 }\n" assertRoundTrip,
      testCase "comments retained in source order, including inside blocks" $
        parsed "-- first\nf = { x = 1; {- inner -} x } -- last\n" $ \m -> do
          prettyModule m @?= "-- first\n{- inner -}\nf = {\n    x = 1;\n    x;\n}\n-- last\n"
          assertRoundTrip m,
      testCase "multiline comments retain their text" $
        parsed "{- first\n\n second -}\nf = 1\n" assertRoundTrip,
      testCase "printing reads the AST rather than the stored source" $
        parsed "f = 1" $ \m -> case moduleDeclarations m of
          [d] -> case concrete d of
            FunctionClause n bs ps e w -> do
              let changed = m {moduleDeclarations = [d {concrete = FunctionClause n bs ps (e {concrete = Lit (IntegerLiteral "2")}) w}]}
              prettyModule changed @?= "f = 2\n"
            other -> assertFailure (show other)
          _ -> assertFailure "expected one declaration",
      testCase "empty module" $ parsed "" (\m -> prettyModule m @?= "")
    ]
  where
    parsed source check = case parseModule "Pretty.ficus" source of
      Left d -> assertFailure (show d)
      Right m -> check m

-- Compare the full typed syntax, ignoring only source maps, retained original
-- text/tokens. Block delimiters are preserved.
normalize :: ConcreteModule -> ConcreteModule
normalize m =
  ConcreteModule
    dummy
    (SourceOrigin dummy)
    (map pragma (modulePragmas m))
    (map importNode (moduleImports m))
    (map decl (moduleDeclarations m))
    []
    [Comment (commentText c) dummy | c <- moduleComments m]
    ""
  where
    dummy = Span "" (Position 1 1 0) (Position 1 1 0)
    node :: (a -> b) -> Located a -> Located b
    node f = at dummy . f . concrete
    name n = n {nameLocation = dummy, nameOrigin = SourceOrigin dummy}
    block :: (a -> b) -> Block a -> Block b
    block f b = Block dummy (SourceOrigin dummy) (blockDelimiter b) (map f (blockItems b))
    pragma = node (\(Pragma n args) -> Pragma (name n) (map (node (\case IdentifierArgument x -> IdentifierArgument (name x); QualifiedIdentifierArgument x xs -> QualifiedIdentifierArgument (name x) (map name xs); StringArgument t -> StringArgument t)) args))
    importNode =
      node
        ( \(Import ns mode) ->
            Import
              (map name ns)
              ( case mode of
                  ModuleOnly -> ModuleOnly
                  Aliased n -> Aliased (name n)
                  AllMembers b -> AllMembers b
                  Selected xs b -> Selected (map (node (\(ImportItem n sel) -> ImportItem (name n) (fmap (\case AllConstructors -> AllConstructors; SelectedConstructors cs -> SelectedConstructors (map name cs)) sel))) xs) b
              )
        )
    parameter = node (\(TypeParameter n k) -> TypeParameter (name n) (fmap kindExpr k))
    binder = node (\(TypeBinder n k) -> TypeBinder (name n) (fmap kindExpr k))
    argument = node (\(TypeArgument t) -> TypeArgument (typeExpr t))
    quantifier = node (\(Quantifier n k) -> Quantifier (name n) (fmap kindExpr k))
    constraint = node (\(Constraint n t) -> Constraint (name n) (typeExpr t))
    signature = node (\(SignatureType qs t) -> SignatureType (map quantifier qs) (typeExpr t))
    whereNode = node (\(WhereClause b) -> WhereClause (block decl b))
    decl = node $ \case
      TypeSignature n t -> TypeSignature (name n) (signature t)
      KindSignature n k -> KindSignature (name n) (kindExpr k)
      FunctionClause n bs ps e w -> FunctionClause (name n) (map binder bs) (map pat ps) (expr e) (fmap whereNode w)
      PatternBinding p e w -> PatternBinding (pat p) (expr e) (fmap whereNode w)
      TypeAlias n ps t -> TypeAlias (name n) (map parameter ps) (typeExpr t)
      DataDeclaration n ps body ->
        DataDeclaration
          (name n)
          (map parameter ps)
          ( case body of
              Constructors b -> Constructors (block (node (\(Constructor c ts) -> Constructor (name c) (map typeExpr ts))) b)
              Fields b -> Fields (block (node (\(FieldSignature f t) -> FieldSignature (name f) (typeExpr t))) b)
          )
      TraitDeclaration cs n p b -> TraitDeclaration (map constraint cs) (name n) (parameter p) (block decl b)
      Implementation cs c b -> Implementation (map constraint cs) (constraint c) (block decl b)
      PragmaDeclaration p -> PragmaDeclaration (pragma p)
    expr = node $ \case
      Ident n -> Ident (name n)
      Lit l -> Lit l
      App f x -> App (expr f) (expr x)
      StaticApp f ts -> StaticApp (expr f) (map argument ts)
      OpApp a op b -> OpApp (expr a) (name op) (expr b)
      Negate e -> Negate (expr e)
      Lam bs ps e -> Lam (map binder bs) (map pat ps) (expr e)
      If b -> If (block (node (\(IfClause c e) -> IfClause (expr c) (expr e))) b)
      With e b -> With (expr e) (block (node (\(MatchClause p g r) -> MatchClause (pat p) (fmap expr g) (expr r))) b)
      Do b -> Do (block (node (\case PatternBind p e -> PatternBind (pat p) (expr e); DoDeclaration d -> DoDeclaration (decl d); DoExpression e -> DoExpression (expr e))) b)
      ExprBlock b -> ExprBlock (block (node (\case LocalDeclaration d -> LocalDeclaration (decl d); Expression e -> Expression (expr e))) b)
      RecordWith e b -> RecordWith (expr e) (block (node (\case Field n r w -> Field (name n) (expr r) (fmap whereNode w); TypeField n t -> TypeField (name n) (typeExpr t))) b)
      Dotted e ns -> Dotted (expr e) (map name ns)
      Paren e -> Paren (expr e)
      Annotated e t -> Annotated (expr e) (typeExpr t)
      Unit -> Unit
      Product es -> Product (map expr es)
      List es -> List (map expr es)
    pat = node $ \case
      IdentP n -> IdentP (name n)
      LitP l -> LitP l
      NegateP p -> NegateP (pat p)
      ConstructorP p ps -> ConstructorP (pat p) (map pat ps)
      RecordP p fields -> RecordP (pat p) (block (node (\(PatternField n q) -> PatternField (name n) (pat q))) fields)
      OpAppP a op b -> OpAppP (pat a) (name op) (pat b)
      ParenP p -> ParenP (pat p)
      AnnotatedP p t -> AnnotatedP (pat p) (typeExpr t)
      UnitP -> UnitP
      ProductP ps -> ProductP (map pat ps)
      ListP ps -> ListP (map pat ps)
      DottedP ns -> DottedP (map name ns)
    typeExpr = node $ \case
      IdentT n -> IdentT (name n)
      DottedT ns -> DottedT (map name ns)
      AppT a b -> AppT (typeExpr a) (typeExpr b)
      OpAppT a op b -> OpAppT (typeExpr a) (name op) (typeExpr b)
      ArrowT a b -> ArrowT (typeExpr a) (typeExpr b)
      ProductT a b -> ProductT (typeExpr a) (typeExpr b)
      ConstrainedT cs t -> ConstrainedT (map constraint cs) (typeExpr t)
      ParenT t -> ParenT (typeExpr t)
      ListT t -> ListT (typeExpr t)
      ListConstructor -> ListConstructor
      ProductConstructor -> ProductConstructor
      FunctionConstructor -> FunctionConstructor
    kindExpr = node $ \case
      IdentK n -> IdentK (name n)
      DottedK ns -> DottedK (map name ns)
      ArrowK a b -> ArrowK (kindExpr a) (kindExpr b)
      ParenK k -> ParenK (kindExpr k)

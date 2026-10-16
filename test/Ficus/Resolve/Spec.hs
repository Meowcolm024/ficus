module Ficus.Resolve.Spec (tests) where

import Data.Aeson (FromJSON (..), eitherDecodeFileStrict', withObject, (.:), (.:?))
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Pretty (prettyDiagnostic)
import Ficus.Error.Resolve
import Ficus.Resolve
import Ficus.Resolve.Discovery
import Ficus.Resolve.Header
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Dependencies
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Name
import Ficus.Util.Source
import System.Directory (listDirectory)
import System.FilePath (takeBaseName, takeExtension, (</>))
import Test.Tasty
import Test.Tasty.HUnit

data Expected = Expected {expectedKind :: Text, expectedSpan :: [Int], expectedCode :: Maybe Text, roots :: Maybe [FilePath]} deriving (Show)

instance FromJSON Expected where
  parseJSON = withObject "resolution expectation" $ \o -> Expected <$> o .: "kind" <*> o .: "span" <*> o .:? "code" <*> o .:? "sourceRoots"

data GraphExpected = GraphExpected {entry :: FilePath, graphRoots :: [FilePath], resultKind :: Text, graphCode :: Maybe Text, primary :: Maybe Primary, modules :: Maybe [Text], initialization :: Maybe [Text]} deriving (Show)

data Primary = Primary FilePath [Int] EdgeOrigin deriving (Show)

instance FromJSON Primary where
  parseJSON = withObject "primary" $ \o -> do
    origin <- o .: "origin"
    Primary <$> o .: "file" <*> o .: "span" <*> pure (if (origin :: Text) == "ImplicitPrelude" then ImplicitPrelude else ExplicitImport)

instance FromJSON GraphExpected where
  parseJSON = withObject "graph expectation" $ \o -> GraphExpected <$> o .: "entry" <*> o .: "sourceRoots" <*> o .: "result" <*> o .:? "code" <*> o .:? "primary" <*> o .:? "modules" <*> o .:? "initializationOrder"

root :: FilePath
root = "test/fixtures/semantics/name-resolution"

tests :: IO TestTree
tests = do
  negative <- eitherDecodeFileStrict' (root </> "expectations.json") >>= either (ioError . userError) pure
  graphCases <- eitherDecodeFileStrict' (root </> "graphs/expectations.json") >>= either (ioError . userError) pure
  positives <- sort . filter ((== ".ficus") . takeExtension) <$> listDirectory (root </> "positive")
  pure
    ( testGroup
        "resolution"
        [ testGroup "negative fixtures" [negativeCase path expected | (path, expected) <- Map.toList negative],
          testGroup "positive fixtures" [positiveCase path | path <- positives],
          testGroup "module discovery" [graphCase path expected | (path, expected) <- Map.toList graphCases],
          duplicateTests,
          unitTests
        ]
    )

negativeCase :: FilePath -> Expected -> TestTree
negativeCase path expected = testCase path $ do
  let directories = fromMaybe ["negative", "support", "../../support"] (roots expected)
      config = ProviderConfig (map (root </>) directories) PreludeFromRoots
  output <- resolveSources fixtureConfig fixtureSugar (fileProvider config) [moduleId (T.pack (takeBaseName path))]
  let matching = [d | ResolutionDiagnostic d <- frontendDiagnostics output, T.pack (show (diagnosticCode d)) == expectedKind expected]
  case matching of
    d : _ -> do
      coordinates (primarySpan d) @?= expectedSpan expected
      mapM_ (\code -> renderResolveCode (diagnosticCode d) @?= code) (expectedCode expected)
    [] -> assertFailure (show (frontendDiagnostics output))

positiveCase :: FilePath -> TestTree
positiveCase path = testCase path $ do
  let config = ProviderConfig [root </> "positive", root </> "support", root </> "../../support"] PreludeFromRoots
  output <- resolveSources fixtureConfig fixtureSugar (fileProvider config) [moduleId (T.pack (takeBaseName path))]
  assertSuccess output

assertSuccess :: FrontendResult -> Assertion
assertSuccess output = do
  errors output @?= []
  assertBool "module returned" (not (Map.null (frontendModules output)))
  mapM_ (\m -> validateAbstract m @?= Right ()) (Map.elems (frontendModules output))

errors :: FrontendResult -> [DiscoveryDiagnostic]
errors output = [d | d <- frontendDiagnostics output, case d of ParseDiagnostic _ -> True; ResolutionDiagnostic r -> severity r == Error]

graphCase :: FilePath -> GraphExpected -> TestTree
graphCase name expected = testCase name $ do
  let base = root </> "graphs" </> name
      provider = fileProvider (ProviderConfig (map (base </>) (graphRoots expected)) PreludeFromRoots)
  graph <- discoverModules provider [moduleId (T.pack (takeBaseName (entry expected)))]
  case resultKind expected of
    "success" -> do
      graphDiagnostics graph @?= []
      mapM_ (\names -> sort (map displayModule (Map.keys (graphModules graph))) @?= sort names) (modules expected)
      mapM_ (\names -> map displayModule (dependencyOrder graph) @?= names) (initialization expected)
    _ -> case [d | ResolutionDiagnostic d <- graphDiagnostics graph, Just (renderResolveCode (diagnosticCode d)) == graphCode expected] of
      d : _ -> case primary expected of
        Just (Primary file span' _) -> do
          takeBaseName (sourceFile (primarySpan d)) @?= takeBaseName file
          coordinates (primarySpan d) @?= span'
        Nothing -> assertFailure "missing primary expectation"
      [] -> assertFailure (show (graphDiagnostics graph))

moduleId :: Text -> ModuleId
moduleId t = ModuleId (t :| [])

displayModule :: ModuleId -> Text
displayModule (ModuleId parts) = T.intercalate "." (foldr (:) [] parts)

coordinates :: Span -> [Int]
coordinates s = [line (start s), column (start s), line (end s), column (end s)]

inMemory :: [(Text, Text)] -> IO FrontendResult
inMemory files = resolveSources fixtureConfig fixtureSugar provider [moduleId "Main"]
  where
    provider owner = pure $ maybe (Left "missing module") (Right . Source (T.unpack (displayModule owner) <> ".ficus")) (lookup (displayModule owner) files)

unitTests :: TestTree
unitTests =
  testGroup
    "stage contracts"
    [ testCase "independent errors accumulate" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\na = absent\nb = other\nc = 3\n")]
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == UnresolvedName] @?= 2
        Map.null (frontendModules out) @?= True,
      testCase "sequential self reference sees the previous scope" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf = { x = x; x }\n")]
        assertBool "unresolved initializer" (any (\case ResolutionDiagnostic d -> diagnosticCode d == UnresolvedName; _ -> False) (frontendDiagnostics out)),
      testCase "duplicate parameter binder" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf x x = x\n")]
        [diagnosticCode d | ResolutionDiagnostic d <- frontendDiagnostics out] @?= [DuplicatePatternBinder],
      testCase "signature variables do not enter parameter annotations" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf : a -> a\nf (x : a) = x\n")]
        [diagnosticCode d | ResolutionDiagnostic d <- frontendDiagnostics out] @?= [InvalidTypeVariableScope],
      testCase "explicit binder and signature have distinct identities" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf : {a} -> a -> a\nf @b (x : b) = x\n")]
        assertSuccess out
        case Map.lookup (moduleId "Main") (frontendModules out) of
          Just m -> case A.declarations (A.abstractDeclarations m) of
            [d] -> case A.nodeValue d of
              A.ValueDefinition _ (Just sig) (A.ClausesBody _ (clause :| [])) -> case (A.nodeValue sig, A.clauseTypes (A.nodeValue clause)) of
                (([signatureBinder], _, _), [definitionBinder]) -> let (signatureId, _, _) = A.nodeValue signatureBinder; (definitionId, _, _) = A.nodeValue definitionBinder in assertBool "separate signature/definition scopes" (signatureId /= definitionId)
                _ -> assertFailure "type binders missing"
              _ -> assertFailure "signature and clause expected"
            _ -> assertFailure "single definition expected"
          Nothing -> assertFailure "Main missing",
      testCase "module aliases defer ambiguity and warn" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nuse Left as M\nuse Right as M\nf = 1\n"), ("Left", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1"), ("Right", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 2")]
        assertSuccess out
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == RepeatedModuleQualifier] @?= 1,
      testCase "bare imports expose only their final component" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nuse Data.Int\nf = Int.x\n"), ("Data.Int", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1")]
        assertSuccess out
        out' <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nuse Data.Int\nf = Data.Int.x\n"), ("Data.Int", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1")]
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out', diagnosticCode d == ModuleNotFound] @?= 1,
      testCase "kind signatures attach to alias declarations" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nIdentity : Type -> Type\nIdentity a = a\n")]
        assertSuccess out,
      testCase "duplicate type declarations fail collection" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\ntype T = { First }\ntype T = { Second }\n")]
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == DuplicateDeclaration] @?= 1,
      testCase "duplicate record labels are declaration errors" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\ntype R = { x : Int; x : Int }\n")]
        [diagnosticCode d | ResolutionDiagnostic d <- frontendDiagnostics out] @?= [DuplicateDeclaration],
      testCase "method and ordinary value cannot share a declaration name" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\ntrait C a = { f : a -> a }\nf x = x\n")]
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == DuplicateDeclaration] @?= 1,
      testCase "duplicate binders in a sequential pattern are source errors" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf = { (x,x) = (1,2); x }\n")]
        [diagnosticCode d | ResolutionDiagnostic d <- frontendDiagnostics out] @?= [DuplicatePatternBinder],
      testCase "shared qualifier selects by exported member" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nuse Left as M\nuse Right as M\nf = M.x\n"), ("Left", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1"), ("Right", "{-# NO_IMPLICIT_PRELUDE #-}\ny = 2")]
        assertSuccess out,
      testCase "module alias ambiguity at use" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nuse Left as M\nuse Right as M\nf = M.x\n"), ("Left", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1"), ("Right", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 2")]
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == AmbiguousName] @?= 1,
      testCase "repeated same-module alias is one candidate" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nuse Left as M\nuse Left as M\nf = M.x\n"), ("Left", "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1")]
        assertSuccess out,
      testCase "discovery continues after a parse error" $ do
        let provider owner = pure (Right (Source (T.unpack (displayModule owner) <> ".ficus") (if owner == moduleId "Bad" then "f =" else "{-# NO_IMPLICIT_PRELUDE #-}\nf = 1")))
        graph <- discoverModules provider [moduleId "Bad", moduleId "Good"]
        Map.member (moduleId "Good") (graphModules graph) @?= True
        length (graphDiagnostics graph) @?= 1,
      testCase "file identities must be uppercase relative paths" $ do
        moduleIdentity "src" "src/Data/Map.ficus" @?= Right (ModuleId ("Data" :| ["Map"]))
        assertBool "lowercase path rejected" (case moduleIdentity "src" "src/main.ficus" of Left _ -> True; Right _ -> False),
      testCase "non-adjacent clauses retain matching order" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf 2 = 20\ng = 0\nf 1 = 10\nf _ = 30\n")]
        assertSuccess out
        case Map.lookup (moduleId "Main") (frontendModules out) of
          Just m -> case [cs | d <- A.declarations (A.abstractDeclarations m), A.ValueDefinition (GlobalRef (GlobalId _ _ "f")) _ (A.ClausesBody _ cs) <- [A.nodeValue d]] of
            [cs] -> [line (start (A.nodeSpan c)) | c <- foldr (:) [] cs] @?= [2, 4, 5]
            _ -> assertFailure "one clause group expected"
          Nothing -> assertFailure "Main missing",
      testCase "lambda patterns match at each unary application" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf = (x,y) z -> x\n")]
        assertSuccess out
        case mainBodies out of
          [body] -> case A.nodeValue body of
            A.Lambda _ match -> case A.nodeValue match of
              A.Match A.WarningCoverage _ [clause] -> case A.nodeValue clause of
                (_, Nothing, next) -> case A.nodeValue next of
                  A.Lambda _ _ -> pure ()
                  _ -> assertFailure "second lambda must follow first match"
                _ -> assertFailure "unexpected generated guard"
              _ -> assertFailure "first argument must match immediately"
            _ -> assertFailure "expected simple-binder lambda"
          _ -> assertFailure "expected one function body",
      testCase "validator rejects dangling local IDs" $ do
        out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\nf x = x\n")]
        assertSuccess out
        case Map.lookup (moduleId "Main") (frontendModules out) of
          Just m -> do
            let breakDeclaration d = case A.nodeValue d of
                  A.ValueDefinition ref sig (A.ClausesBody arity cs) -> d {A.nodeValue = A.ValueDefinition ref sig (A.ClausesBody arity (fmap breakClause cs))}
                  _ -> d
                breakClause c = let cl = A.nodeValue c; body = A.clauseBody cl in c {A.nodeValue = cl {A.clauseBody = body {A.nodeValue = A.Ref (LocalRef (LocalId (-1)))}}}
                group = A.abstractDeclarations m
            assertBool "dangling reference rejected" (case validateAbstract (m {A.abstractDeclarations = group {A.declarations = map breakDeclaration (A.declarations group)}}) of Left _ -> True; Right _ -> False)
          Nothing -> assertFailure "Main missing",
      testCase "Prelude source file is configurable" $ do
        let config = ProviderConfig [root </> "positive", root </> "support"] (PreludeFile "test/fixtures/support/Prelude.ficus")
        out <- resolveSources fixtureConfig fixtureSugar (fileProvider config) [moduleId "UnusedPreludeConflict"]
        assertSuccess out,
      testCase "do and interpolation use canonical sugar contracts" $ do
        let provider owner =
              if owner == moduleId "Main"
                then pure (Right (Source "Main.ficus" "f show stringAppend action = do { Just x <- action; \"value={x}\" }\n"))
                else fileProvider (ProviderConfig ["test/fixtures/support"] PreludeFromRoots) owner
        out <- resolveSources fixtureConfig fixtureSugar provider [moduleId "Main"]
        assertSuccess out
        case Map.lookup (moduleId "Main") (frontendModules out) of
          Just m -> case Map.lookup (GlobalRef (GlobalId (moduleId "Main") ValueNS "f")) (bindingDependencies (A.abstractDeclarations m)) of
            Just deps -> mapM_ (\name -> assertBool "canonical sugar reference" (Set.member (GlobalRef (GlobalId (moduleId "Prelude") ValueNS name)) (valueDependencies deps))) ["bind", "show", "stringAppend"]
            Nothing -> assertFailure "missing dependency metadata"
          Nothing -> assertFailure "Main missing"
        case mainBodies out of
          [body] -> case A.nodeValue body of
            A.Apply first continuation -> do
              case A.nodeValue first of
                A.Apply bind _ -> case A.nodeValue bind of
                  A.Method (GlobalId owner _ "bind") -> owner @?= moduleId "Prelude"
                  _ -> assertFailure "canonical Bind method expected"
                _ -> assertFailure "bind application expected"
              case A.nodeValue continuation of
                A.Lambda _ match -> case A.nodeValue match of
                  A.Match A.RequiredTotal _ _ -> pure ()
                  _ -> assertFailure "required-total obligation missing"
                _ -> assertFailure "continuation must be a simple lambda"
            _ -> assertFailure "do was not expanded"
          _ -> assertFailure "expected one body",
      testCase "the shared Prelude smoke source resolves" $ do
        let config = ProviderConfig ["test/fixtures/semantics/type-checking/positive", "test/fixtures/support"] PreludeFromRoots
        out <- resolveSources fixtureConfig fixtureSugar (fileProvider config) [moduleId "MiniPrelude"]
        assertSuccess out,
      testCase "a bad module does not block an independent valid module" $ do
        let provider owner = pure (Right (Source (T.unpack (moduleText owner) <> ".ficus") (if owner == moduleId "Bad" then "{-# UNKNOWN #-}\n{-# NO_IMPLICIT_PRELUDE #-}\nx = missing\n" else "{-# NO_IMPLICIT_PRELUDE #-}\nx = 1\n")))
        out <- resolveSources fixtureConfig fixtureSugar provider [moduleId "Bad", moduleId "Good"]
        Map.keys (frontendModules out) @?= [moduleId "Good"]
        length [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == UnknownPragma] @?= 1,
      testCase "resolver diagnostics use shared rendering" $ do
        let s = Span "Main.ficus" (Position 1 1 0) (Position 1 1 0)
            d = (diagnostic Shadowing s "shadowed") {relatedSpans = [(s, "earlier binding")]}
            output = prettyDiagnostic "x" d
        assertBool "warning code" ("warning[N0901]" `T.isInfixOf` output)
        assertBool "related label" ("earlier binding" `T.isInfixOf` output)
    ]

mainBodies :: FrontendResult -> [A.Expr]
mainBodies out = [A.clauseBody (A.nodeValue clause) | m <- maybe [] pure (Map.lookup (moduleId "Main") (frontendModules out)), d <- A.declarations (A.abstractDeclarations m), A.ValueDefinition _ _ (A.ClausesBody _ cs) <- [A.nodeValue d], clause <- foldr (:) [] cs]

duplicateTests :: TestTree
duplicateTests =
  testGroup
    "non-function duplicates"
    [ duplicateCase name body expected span'
    | (name, body, expected, span') <-
        [ ("top-level values", "x = 1\nx = 2\n", DuplicateDeclaration, [3, 1, 3, 1]),
          ("where values", "f = x where { x = 1; x = 2 }\n", DuplicateDeclaration, [2, 22, 2, 22]),
          ("aliases", "T = Int\nT = Float\n", DuplicateDeclaration, [3, 1, 3, 1]),
          ("constructors", "type T = { C; C }\n", DuplicateDeclaration, [2, 15, 2, 15]),
          ("record fields", "type R = { x : Int; x : Int }\n", DuplicateDeclaration, [2, 21, 2, 21]),
          ("value signatures", "x : Int\nx : Int\nx = 1\n", DuplicateSignature, [3, 1, 3, 1]),
          ("kind signatures", "T : Type\nT : Type\nT = Int\n", DuplicateSignature, [3, 1, 3, 1]),
          ("trait signatures", "trait C a = { f : a -> a; f : a -> a }\n", DuplicateSignature, [2, 27, 2, 27]),
          ("where pattern declarations", "f = x where { (x,y) = (1,2); x = 3 }\n", DuplicateDeclaration, [2, 30, 2, 30])
        ]
    ]
  where
    duplicateCase name body expected span' = testCase name $ do
      out <- inMemory [("Main", "{-# NO_IMPLICIT_PRELUDE #-}\n" <> body)]
      case [d | ResolutionDiagnostic d <- frontendDiagnostics out, diagnosticCode d == expected] of
        d : _ -> coordinates (primarySpan d) @?= span'
        [] -> assertFailure (show (frontendDiagnostics out))
      Map.member (moduleId "Main") (frontendModules out) @?= False

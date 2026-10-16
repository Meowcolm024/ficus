module Ficus.Resolve.WildcardSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Error.Resolve
import Ficus.Resolve
import Ficus.Resolve.Discovery
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Dependencies
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Name
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

resolveText :: Text -> IO FrontendResult
resolveText source = resolveSources fixtureConfig fixtureSugar provider [ModuleId ("Main" :| [])]
  where
    provider owner
      | owner == ModuleId ("Main" :| []) = pure (Right (Source "Main.ficus" source))
      | otherwise = fileProvider (ProviderConfig ["test/fixtures/semantics/name-resolution/support", "test/fixtures/support"] PreludeFromRoots) owner

isolated :: Text -> Text
isolated = ("{-# NO_IMPLICIT_PRELUDE #-}\n" <>)

success :: Text -> (A.AbstractModule -> Assertion) -> Assertion
success source assertion = do
  result <- resolveText source
  frontendDiagnostics result @?= []
  case Map.lookup (ModuleId ("Main" :| [])) (frontendModules result) of
    Nothing -> assertFailure "expected a successful module"
    Just m -> do
      validateAbstract m @?= Right ()
      Map.member (ValueNS, "_") (A.abstractExports m) @?= False
      assertBool "wildcard is not a resolved occurrence" (all ((/= "_") . A.occurrenceSpelling) (A.abstractOccurrences m))
      assertion m

oneClause :: A.AbstractModule -> (A.ClauseF -> Assertion) -> Assertion
oneClause m assertion = case A.declarations (A.abstractDeclarations m) of
  [d] -> case A.nodeValue d of
    A.ValueDefinition _ _ (A.ClausesBody _ (c :| [])) -> assertion (A.nodeValue c)
    _ -> assertFailure "expected a named value with one clause"
  _ -> assertFailure "expected one declaration"

isDiscard :: A.Declaration -> Bool
isDiscard d = case A.nodeValue d of
  A.PatternDefinition p _ -> A.nodeValue p == A.Wildcard
  _ -> False

assertSequentialDiscards :: A.Expr -> Assertion
assertSequentialDiscards expression = case A.nodeValue expression of
  A.Sequence [statement] rest -> case A.nodeValue statement of
    A.BindStatement group -> do
      A.scopeMode group @?= A.Sequential
      case A.declarations group of
        [d] -> assertBool "unnamed wildcard declaration retained" (isDiscard d)
        _ -> assertFailure "expected one discard binding"
      case A.nodeValue rest of
        A.Sequence _ _ -> assertSequentialDiscards rest
        _ -> pure ()
    _ -> assertFailure "expected sequential binding statement"
  _ -> assertFailure "expected strict sequential discard"

tests :: TestTree
tests =
  testGroup
    "wildcard resolution"
    [ testCase "wildcard head discards an expression hole without naming it" $
        success (isolated "_ = _\n") $ \m -> case A.declarations (A.abstractDeclarations m) of
          [d] -> case A.nodeValue d of
            A.PatternDefinition p rhs -> do
              A.nodeValue p @?= A.Wildcard
              case A.nodeValue rhs of A.Hole _ -> pure (); _ -> assertFailure "RHS must remain an expression hole"
              coordinates (A.nodeSpan p) @?= [2, 1, 2, 1]
              coordinates (A.nodeSpan rhs) @?= [2, 5, 2, 5]
            _ -> assertFailure "wildcard head must be an anonymous pattern definition"
          _ -> assertFailure "expected one discard declaration",
      testCase "repeated top-level wildcard bindings remain separate and ordered" $
        success (isolated "_ = 1\nx = 2\n_ = 3\n") $ \m -> do
          let ds = A.declarations (A.abstractDeclarations m)
          map (line . start . A.nodeSpan) ds @?= [2, 3, 4]
          map isDiscard ds @?= [True, False, True],
      testCase "expression-block wildcards are strict sequential discards" $
        success (isolated "f = { _ = 1; _ = 2; 3 }\n") $
          \m -> oneClause m (assertSequentialDiscards . A.clauseBody),
      testCase "where wildcards introduce no names and do not group" $
        success (isolated "f = answer where { _ = 1; _ = 2; answer = 3 }\n") $ \m -> oneClause m $ \c ->
          map isDiscard (A.declarations (A.clauseWhere c)) @?= [True, True, False],
      testCase "discard bindings retain their own where initialization" $
        success (isolated "_ = local where { local = 1 }\n") $ \m -> case A.declarations (A.abstractDeclarations m) of
          [d] -> case A.nodeValue d of
            A.PatternDefinition p rhs -> do
              A.nodeValue p @?= A.Wildcard
              case A.nodeValue rhs of
                A.Where A.AtInitialization group body -> case A.declarations group of
                  [local] -> case A.nodeValue local of
                    A.ValueDefinition ref _ _ -> A.nodeValue body @?= A.Ref ref
                    _ -> assertFailure "expected a local where binding"
                  _ -> assertFailure "expected one where declaration"
                _ -> assertFailure "discard where group must run at initialization"
            _ -> assertFailure "expected a discard binding"
          _ -> assertFailure "expected one declaration",
      testCase "do declarations retain sequential wildcard bindings" $
        success "f action = do { _ = 1; _ = 2; action }\n" $
          \m -> oneClause m (assertSequentialDiscards . A.clauseBody),
      testCase "repeated wildcard parameters do not bind variables" $
        success (isolated "f _ _ x = x\n") $ \m -> oneClause m $ \c -> case A.clausePatterns c of
          [a, b, x] -> do
            A.nodeValue a @?= A.Wildcard
            A.nodeValue b @?= A.Wildcard
            case A.nodeValue x of
              A.Bind binder -> A.nodeValue (A.clauseBody c) @?= A.Ref (LocalRef (fst (A.nodeValue binder)))
              _ -> assertFailure "x must bind an ordinary local"
          _ -> assertFailure "expected three parameters",
      testCase "wildcard bindings do not turn later expression holes into references" $
        success (isolated "_ = 1\nf = _\n") $ \m -> case A.declarations (A.abstractDeclarations m) of
          [_, d] -> case A.nodeValue d of
            A.ValueDefinition _ _ (A.ClausesBody _ (c :| [])) -> case A.nodeValue (A.clauseBody (A.nodeValue c)) of
              A.Hole _ -> pure ()
              _ -> assertFailure "standalone underscore must remain a hole"
            _ -> assertFailure "expected f definition"
          _ -> assertFailure "expected two declarations",
      testCase "discarded function expressions remain valid anonymous bindings" $
        success (isolated "_ = x -> x\n") $ \m -> case A.declarations (A.abstractDeclarations m) of
          [d] -> case A.nodeValue d of
            A.PatternDefinition p rhs -> do
              A.nodeValue p @?= A.Wildcard
              case A.nodeValue rhs of A.Lambda _ _ -> pure (); _ -> assertFailure "lambda initializer lost"
            _ -> assertFailure "expected a discard binding"
          _ -> assertFailure "expected one declaration",
      testCase "discard initializer dependencies are preserved without a binding identity" $
        success (isolated "f x = x\n_ = f 1\n") $ \m -> case A.declarations (A.abstractDeclarations m) of
          [_, discard] -> do
            let f = GlobalRef (GlobalId (ModuleId ("Main" :| [])) ValueNS "f")
            assertBool "initializer dependency retained" (Set.member f (valueDependencies (declarationDependencies discard)))
            Map.keys (bindingDependencies (A.abstractDeclarations m)) @?= [f]
          _ -> assertFailure "expected a function and an anonymous initializer",
      testCase "validator rejects a wildcard disguised as a global name" $
        success (isolated "f = 1\n") $ \m -> do
          let gid = GlobalId (ModuleId ("Main" :| [])) ValueNS "_"
              entity = A.Entity gid ValueRole (A.abstractSpan m) Nothing
              malformed = m {A.abstractEntities = Map.insert gid entity (A.abstractEntities m)}
          assertBool "invalid wildcard identity rejected" (case validateAbstract malformed of Left _ -> True; Right () -> False),
      testCase "discard initializers are still resolved" $ do
        result <- resolveText (isolated "_ = missing\nf = 1\n")
        case [d | ResolutionDiagnostic d <- frontendDiagnostics result] of
          [d] -> do
            diagnosticCode d @?= UnresolvedName
            coordinates (primarySpan d) @?= [2, 5, 2, 11]
          ds -> assertFailure (show ds),
      testCase "underscore-prefixed names remain ordinary identifiers" $
        success (isolated "_name = 1\nf _arg = _arg\n") $
          \m -> Map.member (ValueNS, "_name") (A.abstractExports m) @?= True,
      testGroup
        "underscore cannot be a name"
        [ testCase label $ do
            result <- resolveText (isolated source)
            case [d | ResolutionDiagnostic d <- frontendDiagnostics result, severity d == Error] of
              [d] -> do
                diagnosticCode d @?= ReservedName
                coordinates (primarySpan d) @?= expected
              ds -> assertFailure (show ds)
        | (label, source, expected) <-
            [ ("function head", "_ x = x\n", [2, 1, 2, 1]),
              ("head with type parameters", "_ @a = 1\n", [2, 1, 2, 1]),
              ("signature target", "_ : Int\n", [2, 1, 2, 1]),
              ("local function head", "f = { _ x = x; 1 }\n", [2, 7, 2, 7]),
              ("where function head", "f = 1 where { _ x = x }\n", [2, 15, 2, 15]),
              ("trait method", "trait C a = { _ : a }\n", [2, 15, 2, 15]),
              ("implementation member", "trait C a = { f : a -> a }\nimpl C Int = { _ x = x }\n", [3, 16, 3, 16]),
              ("type binder", "f @_ x = x\n", [2, 4, 2, 4]),
              ("signature quantifier", "f : {_} -> Int\nf = 1\n", [2, 6, 2, 6]),
              ("type parameter", "type T _ = { C }\n", [2, 8, 2, 8]),
              ("builtin target", "{-# BUILTIN INT_ADD _ #-}\n_ = 1\n", [2, 21, 2, 21]),
              ("import selection", "use Resolve.Left (_)\nf = 1\n", [2, 19, 2, 19]),
              ("qualified value", "use Resolve.Left\nf = Left._\n", [3, 10, 3, 10]),
              ("record field declaration", "type R = { _ : Int }\n", [2, 12, 2, 12]),
              ("record field assignment", "type R = { x : Int }\nf = R with { _ = 1 }\n", [3, 14, 3, 14]),
              ("field projection", "f r = r._\n", [2, 9, 2, 9])
            ]
        ]
    ]

coordinates :: Span -> [Int]
coordinates s = [line (start s), column (start s), line (end s), column (end s)]

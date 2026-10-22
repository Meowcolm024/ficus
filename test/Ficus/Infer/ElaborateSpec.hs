module Ficus.Infer.ElaborateSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.CompilationConfig
import Ficus.Elaborate
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Resolve
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Name
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

check :: Text -> (Elaboration -> Assertion) -> Assertion
check = checkUsing elaborateModule

checkUsing :: ([CheckedInterface] -> A.AbstractModule -> Elaboration) -> Text -> (Elaboration -> Assertion) -> Assertion
checkUsing elaborate source assertion = do
  let owner = ModuleId ("Elaboration" :| [])
  resolved <- resolveSources fixtureConfig fixtureSugar (\_ -> pure (Right (Source "Elaboration.ficus" ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source)))) [owner]
  assertBool (show (frontendDiagnostics resolved)) (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics resolved))
  maybe (assertFailure "fixture did not resolve") (assertion . elaborate []) (Map.lookup owner (frontendModules resolved))

accepted :: Text -> Assertion
accepted source = check source $ \case
  Incomplete _ errors -> assertFailure (show errors)
  Complete result _ -> validateCore (validatedModule (checkedCore result)) @?= []

tests :: TestTree
tests =
  testGroup
    "source elaboration"
    [ testCase "non-exhaustive patterns can be rejected through compilation configuration" $
        mapM_
          ( \config ->
              checkUsing (elaborateModuleWithConfig (config {rejectNonExhaustivePatterns = True})) "choose True = 1\n" $ \case
                Complete _ _ -> assertFailure "non-exhaustive function was accepted"
                Incomplete _ errors -> do
                  map E.diagnosticCode errors @?= [E.NonExhaustiveMatch]
                  map (D.diagnosticSeverity . D.toDiagnostic) errors @?= [D.Error]
                  map (line . start . E.diagnosticSpan) errors @?= [2]
          )
          [defaultCompilationConfig, standaloneCompilationConfig, interactiveCompilationConfig],
      testCase "exhaustiveness rejection preserves diagnostics for every coverage form" $
        mapM_
          ( \source -> check source $ \case
              Incomplete _ errors -> assertFailure (show errors)
              Complete result warnings -> do
                validateCore (validatedModule (checkedCore result)) @?= []
                map E.diagnosticCode warnings @?= [E.NonExhaustiveMatch]
                checkUsing (elaborateModuleWithConfig (defaultCompilationConfig {rejectNonExhaustivePatterns = True})) source $ \case
                  Complete _ _ -> assertFailure "non-exhaustive patterns were accepted"
                  Incomplete _ errors ->
                    map D.toDiagnostic errors @?= map (\warning -> (D.toDiagnostic warning) {D.diagnosticSeverity = D.Error}) warnings
          )
          [ "choose True = 1\n",
            "choose x = with x { True -> 1 }\n",
            "choose x = with x { _ if False -> 1 }\n",
            "choose = (True -> 1)\n",
            "choose () = { True = False; 1 }\n",
            "choose x = with x {}\n"
          ],
      testCase "strict exhaustiveness accepts complete matches and retains redundancy warnings" $
        checkUsing (elaborateModuleWithConfig (defaultCompilationConfig {rejectNonExhaustivePatterns = True})) "choose _ = 1\nchoose True = 2\n" $ \case
          Incomplete _ errors -> assertFailure (show errors)
          Complete result warnings -> do
            validateCore (validatedModule (checkedCore result)) @?= []
            map E.diagnosticCode warnings @?= [E.RedundantClause]
            map (D.diagnosticSeverity . D.toDiagnostic) warnings @?= [D.Warning],
      testCase "strict exhaustiveness accepts empty matches on uninhabited types" $
        checkUsing (elaborateModuleWithConfig (defaultCompilationConfig {rejectNonExhaustivePatterns = True})) "type Void = {}\nabsurd : Void -> Int\nabsurd x = with x {}\n" $ \case
          Incomplete _ errors -> assertFailure (show errors)
          Complete result warnings -> do
            validateCore (validatedModule (checkedCore result)) @?= []
            warnings @?= [],
      testCase "initializer checks are independent of implementation policies" $
        mapM_
          ( \config -> checkUsing (elaborateModuleWithConfig config) "identity x = x\nvalue = identity 1\n" $ \case
              Complete result warnings -> do
                assertBool "initializer checks should be disabled" (not (checkTopLevelInitializers config))
                let core = validatedModule (checkedCore result)
                C.coreCompilationConfig core @?= config
                validateCore core @?= []
                warnings @?= []
              Incomplete _ errors -> do
                assertBool "initializer checks should be enabled" (checkTopLevelInitializers config)
                map E.diagnosticCode errors @?= [E.ExpansiveInitializer]
                map (line . start . E.diagnosticSpan) errors @?= [3]
          )
          [ defaultCompilationConfig {checkTopLevelInitializers = initializers, checkOrphanImplementations = orphans, allowImportedImplementationOverrides = overrides}
          | initializers <- [False, True],
            orphans <- [False, True],
            overrides <- [False, True]
          ],
      testCase "builtin Handle elaborates through checked Core" $
        accepted "{-# BUILTIN HANDLE Handle #-}\nHandle : Type\nidentity : Handle -> Handle\nidentity handle = handle\n",
      testCase "polymorphic constructor values lower to unary closures" $
        accepted "type Box a = Box a\nbox = Box\ncheck () = (box 1, box True)\n",
      testCase "local destructuring preserves independent polymorphic uses" $
        accepted "check () = { (identity, other) = (x -> x, y -> y); (identity 1, identity True, other 2) }\n",
      testCase "unused inferred argument types remain locally scoped" $
        accepted "constant x y = x\ncheck () = constant 1 (x -> x)\n",
      testCase "signed and unsigned recursive members elaborate together" $
        accepted "first : a -> Int\nfirst x = second x\nsecond x = first x\n",
      testCase "mutually recursive constrained members receive evidence" $
        accepted "trait Show a = { show : a -> String }\nfirst x = second x\nsecond x = if { True -> show x; _ -> first x }\n",
      testCase "discarded polymorphic initializers retain their type scope" $
        accepted "_ = x -> x\ncheck () = { _ = x -> x; 1 }\n",
      testCase "discarded constrained lambdas abstract their evidence" $
        accepted "trait Show a = { show : a -> String }\n_ = x -> show x\n",
      testCase "dictionary-dependent where initialization waits for evidence" $
        check "type Maybe a = { Nothing; Just a }\ntrait Get a = { get : Maybe a }\nchoose : Get a => a -> a\nchoose = x -> y where { Just y = get }\n" $ \case
          Incomplete _ errors -> assertFailure (show errors)
          Complete checked _ -> do
            let core = validatedModule (checkedCore checked)
                bodies = [C.bindingBody (C.nodeValue binding) | group <- C.coreBindings core, binding <- C.groupBindings group, GlobalRef (GlobalId _ _ "choose") <- [C.bindingReference (C.nodeValue binding)]]
            validateCore core @?= []
            case bodies of
              [body] -> case C.formOf body of
                C.Lambda binder initializer -> do
                  let (_, _, role, _) = C.nodeValue binder
                  role @?= C.EvidenceBinder
                  assertBool "where match precedes the returned value lambda" (case C.formOf initializer of C.Let {} -> True; _ -> False)
                _ -> assertFailure "initializer lacks its evidence parameter"
              _ -> assertFailure "missing choose binding",
      testCase "implementation initializers retain member source order" $
        check "trait Pair a = { alpha : a -> a; zeta : a -> a }\nimpl Pair Int = { zeta = x -> x; alpha = y -> y }\n" $ \case
          Incomplete _ errors -> assertFailure (show errors)
          Complete checked _ -> do
            let bodies = [C.bindingBody (C.nodeValue binding) | group <- C.coreBindings (validatedModule (checkedCore checked)), binding <- C.groupBindings group]
            case bodies of
              [body] -> case C.formOf body of
                C.Let first rest -> case C.formOf rest of
                  C.Let second _ -> assertBool "member initialization follows source order" (start (C.nodeSpan first) < start (C.nodeSpan second))
                  _ -> assertFailure "second method initializer is not shared"
                _ -> assertFailure "method initializers are evaluated directly in dictionary slot order"
              _ -> assertFailure "missing dictionary binding",
      testCase "implementation member aliases follow their dependencies" $
        accepted "trait Pair a = { alpha : a -> a; zeta : a -> a }\nimpl Pair Int = { zeta = alpha; alpha = x -> x }\n",
      testCase "a typed hole retains diagnostic Core but cannot complete" $
        check "missing : Int -> Int\nmissing x = _\n" $ \case
          Complete _ _ -> assertFailure "hole was accepted"
          Incomplete partial errors -> do
            map E.diagnosticCode (filter ((== D.Error) . D.diagnosticSeverity . D.toDiagnostic) errors) @?= [E.ExpressionHole]
            map (\d -> (line (start (E.diagnosticSpan d)), column (start (E.diagnosticSpan d)))) errors @?= [(3, 13)]
            case partial of
              Nothing -> assertFailure "hole lost its diagnostic Core"
              Just core -> do
                validateCore core @?= []
                length (concatMap (C.expressionHoles . C.bindingBody . C.nodeValue) (concatMap C.groupBindings (C.coreBindings core))) @?= 1,
      testCase "dictionary construction cannot read itself during initialization" $
        check "trait Show a = { show : a -> String }\nimpl Show Int = { show = show }\n" $ \case
          Complete _ _ -> assertFailure "recursive dictionary initializer was accepted"
          Incomplete _ errors -> do
            let matching = filter ((== E.UnsafeRecursiveInitialization) . E.diagnosticCode) errors
            assertBool (show errors) (not (null matching))
            map (line . start . E.diagnosticSpan) matching @?= [3]
    ]

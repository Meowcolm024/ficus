module Ficus.Infer.DeclarationSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.CompilationConfig
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Declaration
import Ficus.Infer.Monad
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Resolve
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name
import Ficus.Type
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

check :: Text -> (Declarations -> [E.Diagnostic] -> Assertion) -> Assertion
check source assertion = do
  let owner = ModuleId ("Declarations" :| [])
  result <- resolveSources fixtureConfig fixtureSugar (\_ -> pure (Right (Source "Declarations.ficus" ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source)))) [owner]
  frontendDiagnostics result @?= []
  case Map.lookup owner (frontendModules result) of
    Nothing -> assertFailure "fixture did not resolve"
    Just tree -> do
      validateAbstract tree @?= Right ()
      let (prepared, state) = runInfer (prepareDeclarations emptyDeclarations tree)
      assertion prepared (diagnostics state)

named :: Namespace -> Text -> GlobalId
named = GlobalId (ModuleId ("Declarations" :| []))

noErrors :: [E.Diagnostic] -> Assertion
noErrors diagnostics' = assertBool (show diagnostics') (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) diagnostics')

tests :: TestTree
tests =
  testGroup
    "semantic declarations"
    [ testCase "orphan checks and imported implementation overrides are independent" $ do
        let base = ModuleId ("ImplementationBase" :| [])
            client = ModuleId ("ImplementationClient" :| [])
            provider owner =
              pure
                ( Right
                    ( if owner == base
                        then Source "ImplementationBase.ficus" "{-# NO_IMPLICIT_PRELUDE #-}\ntrait Marker a = {}\nimpl Marker Int = {}\n"
                        else Source "ImplementationClient.ficus" "{-# NO_IMPLICIT_PRELUDE #-}\nuse ImplementationBase (..)\nimpl Marker Int = {}\n"
                    )
                )
        resolved <- resolveSources fixtureConfig fixtureSugar provider [client]
        frontendDiagnostics resolved @?= []
        case (Map.lookup base (frontendModules resolved), Map.lookup client (frontendModules resolved)) of
          (Just baseTree, Just clientTree) -> do
            validateAbstract baseTree @?= Right ()
            validateAbstract clientTree @?= Right ()
            let (imported, state) = runInfer (prepareDeclarations emptyDeclarations baseTree)
            noErrors (diagnostics state)
            mapM_
              ( \(orphans, overrides) -> do
                  let config = defaultCompilationConfig {checkOrphanImplementations = orphans, allowImportedImplementationOverrides = overrides}
                      (prepared, checked) = runInfer (prepareDeclarationsWithConfig config imported clientTree)
                      errors = diagnostics checked
                  map E.diagnosticCode errors @?= [E.OrphanImplementation | orphans] ++ [E.OverlappingImplementations | not overrides]
                  map (\d -> let origin = E.diagnosticSpan d in (sourceFile origin, line (start origin), column (start origin), column (end origin))) errors
                    @?= [("ImplementationClient.ficus", 3, 6, 15) | orphans] ++ [("ImplementationClient.ficus", 3, 1, 20) | not overrides]
                  Map.size (implementationDeclarations prepared) @?= if overrides then 1 else 2
              )
              [(orphans, overrides) | orphans <- [False, True], overrides <- [False, True]]
          _ -> assertFailure "implementation fixtures did not resolve",
      testCase "aliases expand across forward dependencies" $
        check "First a = Second a\nSecond a = [a]\nvalue : First Int\nvalue = []\n" $ \prepared errors -> do
          noErrors errors
          fmap (renderInferType . schemeType . signatureScheme) (Map.lookup (GlobalRef (named ValueNS "value")) (valueSignatures prepared)) @?= Just "[Int]",
      testCase "constructor schemes retain nominal identity and field order" $
        check "type Pair a b = Pair a b\n" $ \prepared errors -> do
          noErrors errors
          case Map.lookup (C.DataConstructor (named ConstructorNS "Pair")) (constructorDeclarations prepared) of
            Nothing -> assertFailure "missing constructor"
            Just node -> do
              let descriptor = C.nodeValue node
              C.constructorOwner descriptor @?= named TypeNS "Pair"
              C.constructorArity descriptor @?= 2
              length (quantifiers (C.constructorScheme descriptor)) @?= 2,
      testCase "record field schemes are scoped to their nominal receiver" $
        check "type Box a = { value : a }\n" $ \prepared errors -> do
          noErrors errors
          case Map.lookup (named TypeNS "Box") (recordDeclarations prepared) of
            Nothing -> assertFailure "missing record"
            Just record -> do
              let fields = C.recordFields (C.nodeValue record)
              map (fst . C.nodeValue) fields @?= ["value"]
              map (length . quantifiers . snd . C.nodeValue) fields @?= [1],
      testCase "alias cycles have a dedicated diagnostic" $
        check "First = Second\nSecond = First\n" $ \_ errors ->
          map E.diagnosticCode errors @?= [E.CyclicAlias, E.CyclicAlias],
      testCase "aliases cannot be passed unsaturated" $
        check "Alias a = [a]\ntype Container f = Wrap (f Int)\nvalue : Container Alias\nvalue = _\n" $ \_ errors -> do
          assertBool "unsaturated alias" (E.UnsaturatedAlias `elem` map E.diagnosticCode errors)
          map (\d -> (line (start (E.diagnosticSpan d)), column (start (E.diagnosticSpan d)))) (filter ((== E.UnsaturatedAlias) . E.diagnosticCode) errors) @?= [(4, 19)],
      testCase "type-only alias holes are rejected at their occurrence" $
        check "Alias = _\n" $ \_ errors -> do
          map E.diagnosticCode errors @?= [E.InvalidTypeHole]
          map (column . start . E.diagnosticSpan) errors @?= [9],
      testCase "signature holes retain shared inference metavariables" $
        check "keep : Int -> _\nkeep x = x\n" $ \prepared errors -> do
          noErrors errors
          case Map.lookup (GlobalRef (named ValueNS "keep")) (valueSignatures prepared) of
            Nothing -> assertFailure "missing signature"
            Just signature -> signatureHasHoles signature @?= True,
      testCase "method schemes include owner and method-level constraints" $
        check "trait Show a = { show : a -> String }\ntrait Convert a = { convert : Show b => a -> b -> String }\n" $ \prepared errors -> do
          noErrors errors
          case Map.lookup (GlobalRef (named ValueNS "convert")) (valueSignatures prepared) of
            Nothing -> assertFailure "missing method"
            Just signature -> map predicateTrait (schemePredicates (signatureScheme signature)) @?= [named TypeNS "Convert", named TypeNS "Show"],
      testCase "trait signatures do not admit type holes" $
        check "trait Bad a = { bad : a -> _ }\n" $ \_ errors ->
          map E.diagnosticCode errors @?= [E.InvalidTypeHole],
      testCase "recursive algebraic types preserve their parameters" $
        check "type Tree a = { Leaf a; Branch (Tree a) (Tree a) }\n" $
          \_ errors -> noErrors errors,
      testCase "non-regular recursion is rejected at its field" $
        check "type Nest a = Wrap (Nest [a])\n" $ \_ errors -> do
          map E.diagnosticCode errors @?= [E.NonRegularData]
          map (\d -> (line (start (E.diagnosticSpan d)), column (start (E.diagnosticSpan d)), column (end (E.diagnosticSpan d)))) errors @?= [(2, 20, 29)],
      testCase "mutual recursion cannot hide a changed parameter" $
        check "type First a = First (Second [a])\ntype Second b = Second (First b)\n" $ \_ errors ->
          assertBool (show errors) (E.NonRegularData `elem` map E.diagnosticCode errors),
      testCase "alias expansion cannot hide a changed recursive parameter" $
        check "Items a = [a]\ntype Nest a = Wrap (Nest (Items a))\n" $ \_ errors ->
          assertBool (show errors) (E.NonRegularData `elem` map E.diagnosticCode errors),
      testCase "a method must mention its owning trait parameter" $
        check "trait Bad a = { value : Int }\n" $ \_ errors ->
          assertBool (show errors) (E.InvalidTrait `elem` map E.diagnosticCode errors),
      testCase "supertraits must refer to the same parameter" $
        check "trait Parent a = {}\ntrait Parent Int => Child a = {}\n" $ \_ errors ->
          assertBool (show errors) (E.InvalidTrait `elem` map E.diagnosticCode errors),
      testCase "superclass cycles have a dedicated diagnostic" $
        check "trait Second a => First a = {}\ntrait First a => Second a = {}\n" $ \_ errors ->
          map E.diagnosticCode (filter ((== D.Error) . D.diagnosticSeverity . D.toDiagnostic) errors) @?= [E.CyclicSupertraits, E.CyclicSupertraits],
      testCase "implementations must supply every method" $
        check "trait Show a = { show : a -> String }\nimpl Show Int = {}\n" $ \_ errors ->
          assertBool (show errors) (E.InvalidImplementation `elem` map E.diagnosticCode errors),
      testCase "implementation head arguments must be bare variables" $
        check "trait Marker a = {}\nimpl Marker [Int] = {}\n" $ \_ errors ->
          assertBool (show errors) (E.InvalidImplementation `elem` map E.diagnosticCode errors),
      testCase "visible overlapping implementations are rejected" $
        check "trait Marker a = {}\nimpl Marker Int = {}\nimpl Marker Int = {}\n" $ \_ errors ->
          assertBool (show errors) (E.OverlappingImplementations `elem` map E.diagnosticCode errors)
    ]

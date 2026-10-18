module Ficus.Infer.KindSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.Error.Type qualified as E
import Ficus.Infer.Kind
import Ficus.Resolve
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

check :: Text -> (KindSummary -> Assertion) -> Assertion
check source assertion = do
  let owner = ModuleId ("Kinds" :| [])
  result <- resolveSources fixtureConfig fixtureSugar (\_ -> pure (Right (Source "Kinds.ficus" ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source)))) [owner]
  frontendDiagnostics result @?= []
  case Map.lookup owner (frontendModules result) of
    Nothing -> assertFailure "fixture did not resolve"
    Just tree -> do
      validateAbstract tree @?= Right ()
      assertion (inferKinds Map.empty tree)

named :: Text -> GlobalId
named = GlobalId (ModuleId ("Kinds" :| [])) TypeNS

tests :: TestTree
tests =
  testGroup
    "declaration kinds"
    [ testCase "ADT parameters infer ordinary kinds" $
        check "type Maybe a = { Nothing; Just a }\n" $ \result -> do
          Map.lookup (named "Maybe") (constructorKinds result) @?= Just (KindArrow TypeKind TypeKind)
          kindDiagnostics result @?= [],
      testCase "higher-kinded parameters are inferred from constructor fields" $
        check "type Container f a = Wrap a (f a)\n" $ \result -> do
          Map.lookup (named "Container") (constructorKinds result) @?= Just (KindArrow (KindArrow TypeKind TypeKind) (KindArrow TypeKind TypeKind))
          kindDiagnostics result @?= [],
      testCase "mutually recursive declarations share kind constraints" $
        check "type Left f a = L (Right f a)\ntype Right f a = R a (f a)\n" $ \result -> do
          Map.lookup (named "Left") (constructorKinds result) @?= Map.lookup (named "Right") (constructorKinds result)
          kindDiagnostics result @?= [],
      testCase "trait methods constrain their parameter kinds" $
        check "trait Functor f = { map : (a -> b) -> f a -> f b }\n" $ \result -> do
          Map.lookup (named "Functor") (constructorKinds result) @?= Just (KindArrow (KindArrow TypeKind TypeKind) TypeKind)
          kindDiagnostics result @?= [],
      testCase "declared kind mismatches report the offending type span" $
        check "type Bad (f : Type) = Bad (f Int)\n" $ \result -> do
          map E.diagnosticCode (kindDiagnostics result) @?= [E.KindMismatch]
          map (\d -> let s = E.diagnosticSpan d in (line (start s), column (start s), column (end s))) (kindDiagnostics result) @?= [(2, 30, 32)],
      testCase "phantom parameter kinds default with a warning" $
        check "type Phantom a = Phantom\n" $ \result -> do
          Map.lookup (named "Phantom") (constructorKinds result) @?= Just (KindArrow TypeKind TypeKind)
          map E.diagnosticCode (kindDiagnostics result) @?= [E.KindDefaulting]
          map (column . start . E.diagnosticSpan) (kindDiagnostics result) @?= [14],
      testCase "kind holes solve independently" $
        check "Container : _ -> _ -> Type\ntype Container f a = Wrap a (f a)\n" $ \result -> do
          Map.lookup (named "Container") (constructorKinds result) @?= Just (KindArrow (KindArrow TypeKind TypeKind) (KindArrow TypeKind TypeKind))
          kindDiagnostics result @?= [],
      testCase "self application has an infinite kind" $
        check "Bad f = f f\n" $ \result ->
          assertBool "occurs check" (E.KindMismatch `elem` map E.diagnosticCode (kindDiagnostics result))
    ]

module Ficus.Builtin.RegistrySpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Builtin.Registry
import Ficus.Library.Contracts (libraryResolveConfig)
import Ficus.Primitive.Registry qualified as P
import Ficus.Resolve.Desugar qualified as Resolve
import Ficus.Resolve.Support (fixtureConfig)
import Ficus.Syntax.Core.Intrinsic (matchesPrimitive, primitiveSignature)
import Ficus.Syntax.Name (GlobalId (..), ModuleId (..), Namespace (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "builtin registry"
    [ testCase "resolver configurations use the compiler inventory" $ do
        Resolve.builtinKeys libraryResolveConfig @?= builtinKeys
        Resolve.builtinKeys fixtureConfig @?= builtinKeys,
      testCase "shared catalogue keys and erased operations are unique" $ do
        let keys = [key | (Just key, _) <- P.primitiveCatalog]
        Set.size (Set.fromList keys) @?= length keys
        Set.size (Set.fromList P.allPrimitives) @?= length P.allPrimitives
        mapM_ (\(index, operation) -> P.primitiveIndex operation @?= Just index) (zip [0 ..] P.allPrimitives),
      testCase "frontend signatures and shared operand counts agree, including negation" $
        mapM_
          ( \(_, template) -> do
              let operation = fmap (\_ -> renamed) template
                  (inputs, output) = primitiveSignature operation
              length inputs @?= P.primitiveArity template
              assertBool "shared signature conversion validates" (matchesPrimitive operation inputs output)
              P.primitiveIndex operation @?= P.primitiveIndex template
          )
          P.primitiveCatalog,
      testCase "shared erasure preserves operations while removing nominal identities" $ do
        P.erasePrimitive (P.HandleRead renamed) @?= P.HandleRead ()
        P.erasePrimitive (P.VecFromList renamed) @?= P.VecFromList (),
      testCase "type and value contracts have distinct lookups" $
        mapM_ check (Map.toList builtinRegistry),
      testCase "all registered value signatures pass the independent primitive checker" $
        mapM_
          ( \primitive ->
              let (inputs, output) = primitiveSignature primitive
               in do
                    assertBool "complete signature" (matchesPrimitive primitive inputs output)
                    assertBool "wrong arity" (not (matchesPrimitive primitive (output : inputs) output))
          )
          [primitive | ValueBuiltin primitive <- Map.elems builtinRegistry],
      testCase "IO helpers no longer have primitive keys" $
        mapM_
          ( \key -> do
              primitiveFromKey key @?= Nothing
              assertBool "derived IO key removed" (Set.notMember key builtinKeys)
          )
          ["PRINT", "PRINTLN", "READ_LINE"],
      testCase "empty-type elimination needs no compiler keys" $
        mapM_
          ( \key -> do
              primitiveFromKey key @?= Nothing
              typeKindFromKey key @?= Nothing
              assertBool "empty-type key removed" (Set.notMember key builtinKeys)
          )
          ["VOID", "ABSURD"],
      testCase "unregistered keys have no contracts" $ do
        primitiveFromKey "UNKNOWN" @?= Nothing
        typeKindFromKey "UNKNOWN" @?= Nothing
        assertBool "unknown key is not advertised" (Set.notMember "UNKNOWN" builtinKeys)
    ]
  where
    renamed = GlobalId (ModuleId ("Renamed" :| [])) TypeNS "Opaque"
    check (key, ValueBuiltin primitive) = do
      primitiveFromKey key @?= Just primitive
      typeKindFromKey key @?= Nothing
    check (key, TypeBuiltin kind) = do
      typeKindFromKey key @?= Just kind
      primitiveFromKey key @?= Nothing
    check (key, TraitBuiltin _) = do
      typeKindFromKey key @?= Nothing
      primitiveFromKey key @?= Nothing
    check (key, MethodBuiltin) = do
      typeKindFromKey key @?= Nothing
      primitiveFromKey key @?= Nothing
    check (key, DataBuiltin) = do
      typeKindFromKey key @?= Nothing
      primitiveFromKey key @?= Nothing
    check (key, ConstrBuiltin _ _) = do
      typeKindFromKey key @?= Nothing
      primitiveFromKey key @?= Nothing
    check (key, MemberBuiltin _ _) = do
      typeKindFromKey key @?= Nothing
      primitiveFromKey key @?= Nothing

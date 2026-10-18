module Ficus.Builtin.RegistrySpec (tests) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Builtin.Registry
import Ficus.Library.Contracts (libraryResolveConfig)
import Ficus.Resolve.Desugar qualified as Resolve
import Ficus.Resolve.Support (fixtureConfig)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "builtin registry"
    [ testCase "resolver configurations use the compiler inventory" $ do
        Resolve.builtinKeys libraryResolveConfig @?= builtinKeys
        Resolve.builtinKeys fixtureConfig @?= builtinKeys,
      testCase "type and value contracts have distinct lookups" $
        mapM_ check (Map.toList builtinRegistry),
      testCase "unregistered keys have no contracts" $ do
        primitiveFromKey "UNKNOWN" @?= Nothing
        typeKindFromKey "UNKNOWN" @?= Nothing
        assertBool "unknown key is not advertised" (Set.notMember "UNKNOWN" builtinKeys)
    ]
  where
    check (key, ValueBuiltin primitive) = do
      primitiveFromKey key @?= Just primitive
      typeKindFromKey key @?= Nothing
    check (key, TypeBuiltin kind) = do
      typeKindFromKey key @?= Just kind
      primitiveFromKey key @?= Nothing

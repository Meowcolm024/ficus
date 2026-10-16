module Ficus.Resolve.Support (fixtureConfig, fixtureSugar) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Desugar.Registry
import Ficus.Resolve.Desugar
import Ficus.Syntax.Name

fixtureConfig :: ResolveConfig
fixtureConfig =
  ResolveConfig
    (Set.fromList ["INT_ADD", "INT_SUB", "INT_MUL", "INT_DIV", "INT_REM", "INT_EQ", "INT_LT", "INT_SHOW", "STRING_APPEND", "STRING_EQ", "STRING_LENGTH"])

fixtureSugar :: SugarRegistry
fixtureSugar = SugarRegistry (Map.fromList [(SugarKey "do.bind", global "bind"), (SugarKey "string.show", global "show"), (SugarKey "string.append", global "stringAppend")])
  where
    global = GlobalId (ModuleId ("Prelude" :| [])) ValueNS

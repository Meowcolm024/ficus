-- | Contracts for the early-development placeholder library. The resolver and
-- sugar passes accept these independently; neither depends on this inventory.
module Ficus.Library.Contracts (libraryResolveConfig, librarySugarRegistry) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Desugar.Registry
import Ficus.Resolve.Desugar (ResolveConfig (..))
import Ficus.Syntax.Name

libraryResolveConfig :: ResolveConfig
libraryResolveConfig = ResolveConfig (Set.fromList ["INT_ADD", "INT_SUB", "INT_MUL", "INT_DIV", "INT_REM", "INT_EQ", "INT_LT", "INT_SHOW", "STRING_APPEND", "STRING_EQ", "STRING_LENGTH"])

librarySugarRegistry :: SugarRegistry
librarySugarRegistry = SugarRegistry (Map.fromList [(SugarKey "do.bind", global "bind"), (SugarKey "string.show", global "show"), (SugarKey "string.append", global "stringAppend")])
  where
    global = GlobalId (ModuleId ("Prelude" :| [])) ValueNS

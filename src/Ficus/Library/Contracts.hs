-- | Contracts for the early-development placeholder library. The resolver and
-- sugar passes accept these independently; neither depends on this inventory.
module Ficus.Library.Contracts (libraryResolveConfig, librarySugarRegistry) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Ficus.Builtin.Registry qualified as Builtin
import Ficus.Desugar.Registry
import Ficus.Resolve.Desugar (ResolveConfig (..))
import Ficus.Syntax.Name

libraryResolveConfig :: ResolveConfig
libraryResolveConfig = ResolveConfig Builtin.builtinKeys

librarySugarRegistry :: SugarRegistry
librarySugarRegistry = SugarRegistry (Map.fromList [(SugarKey "do.bind", global "bind"), (SugarKey "string.show", global "show"), (SugarKey "string.append", global "stringAppend")])
  where
    global = GlobalId (ModuleId ("Prelude" :| [])) ValueNS

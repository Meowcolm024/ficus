module Ficus.Resolve.Support (fixtureConfig, fixtureSugar) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Ficus.Builtin.Registry qualified as Builtin
import Ficus.Desugar.Registry
import Ficus.Resolve.Desugar
import Ficus.Syntax.Name

fixtureConfig :: ResolveConfig
fixtureConfig = ResolveConfig Builtin.builtinKeys

fixtureSugar :: SugarRegistry
fixtureSugar = SugarRegistry (Map.fromList [(SugarKey "do.bind", global "bind"), (SugarKey "string.append", global "stringAppend")])
  where
    global = GlobalId (ModuleId ("Prelude" :| [])) ValueNS

-- | Library identities required by syntax expansions. Keys are extensible;
-- callers choose their contracts independently of resolver configuration.
module Ficus.Desugar.Registry where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Ficus.Syntax.Name (GlobalId)

newtype SugarKey = SugarKey Text deriving (Eq, Ord, Show)

newtype SugarRegistry = SugarRegistry {sugarBindings :: Map SugarKey GlobalId} deriving (Eq, Show)

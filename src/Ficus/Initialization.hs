-- | Explicit initialization policy, selected by the driver rather than syntax.
module Ficus.Initialization (InitializationMode (..)) where

data InitializationMode = OrdinaryInitialization | InteractiveInitialization deriving (Eq, Show)

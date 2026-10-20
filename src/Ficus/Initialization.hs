-- | Explicit initialization policy, selected by module metadata or the driver.
module Ficus.Initialization (InitializationMode (..)) where

data InitializationMode = OrdinaryInitialization | StandaloneInitialization | InteractiveInitialization deriving (Eq, Show)

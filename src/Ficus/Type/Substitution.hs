-- | Simultaneous, capture-free substitution. Composition is ordered: applying
-- @compose newer older@ means applying older first, then newer.
module Ficus.Type.Substitution
  ( Substitution,
    empty,
    singleton,
    fromBindings,
    apply,
    compose,
    without,
    bindings,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Ficus.Type

newtype Substitution v = Substitution (Map v (Type v)) deriving (Eq, Show)

empty :: Substitution v
empty = Substitution Map.empty

singleton :: v -> Type v -> Substitution v
singleton v t = Substitution (Map.singleton v t)

-- | Construct a simultaneous substitution without rewriting its ranges. This
-- is needed by one-way matching, where target variables are immutable.
fromBindings :: (Ord v) => [(v, Type v)] -> Substitution v
fromBindings = Substitution . Map.fromList

apply :: (Ord v) => Substitution v -> Type v -> Type v
apply substitution@(Substitution mapping) ty = case ty of
  Variable v _ -> Map.findWithDefault ty v mapping
  Constructor {} -> ty
  Application f x -> Application (apply substitution f) (apply substitution x)

compose :: (Ord v) => Substitution v -> Substitution v -> Substitution v
compose newer@(Substitution new) (Substitution old) =
  Substitution (Map.map (apply newer) old `Map.union` new)

without :: (Ord v) => Set v -> Substitution v -> Substitution v
without vs (Substitution mapping) = Substitution (Map.withoutKeys mapping vs)

bindings :: Substitution v -> [(v, Type v)]
bindings (Substitution mapping) = Map.toList mapping

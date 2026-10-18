-- | Equality solving and one-way matching have deliberately different rules.
-- Matching cannot specialize a wanted variable just to select an implementation.
module Ficus.Infer.Unify (UnificationError (..), unify, match) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Infer.Type
import Ficus.Type
import Ficus.Type.Substitution (Substitution)
import Ficus.Type.Substitution qualified as S

data UnificationError
  = TypesDiffer InferType InferType
  | InfiniteType MetaId InferType
  | KindsDiffer KindError
  deriving (Eq, Show)

unify :: InferType -> InferType -> Either UnificationError (Substitution InferVariable)
unify left right = do
  checkKinds left right
  solve left right
  where
    solve a b
      | a == b = Right S.empty
    solve (Variable (Meta v) k) t = bind v k t
    solve t (Variable (Meta v) k) = bind v k t
    solve (Application f x) (Application g y) = do
      first <- unify f g
      second <- unify (S.apply first x) (S.apply first y)
      pure (S.compose second first)
    solve a b = Left (TypesDiffer a b)

bind :: MetaId -> Kind -> InferType -> Either UnificationError (Substitution InferVariable)
bind v k t
  | Set.member (Meta v) (freeVariables t) = Left (InfiniteType v t)
  | otherwise = do
      checkKinds (Variable (Meta v) k) t
      pure (S.singleton (Meta v) t)

checkKinds :: InferType -> InferType -> Either UnificationError ()
checkKinds a b = do
  ak <- either (Left . KindsDiffer) Right (kindOf a)
  bk <- either (Left . KindsDiffer) Right (kindOf b)
  if ak == bk then Right () else Left (KindsDiffer (KindMismatch ak bk))

-- | Only metas in the pattern may be assigned. All other variables are rigid.
-- Repeated pattern variables must match exactly the same target type.
match :: InferType -> InferType -> Either UnificationError (Substitution InferVariable)
match patternType targetType = do
  checkKinds patternType targetType
  S.fromBindings . Map.toList <$> go Map.empty patternType targetType
  where
    go substitution (Variable v@(Meta m) k) target =
      case Map.lookup v substitution of
        Just previous
          | previous == target -> Right substitution
          | otherwise -> Left (TypesDiffer previous target)
        Nothing
          | Variable v k == target -> Right (Map.insert v target substitution)
          | otherwise -> do
              _ <- bind m k target
              pure (Map.insert v target substitution)
    go substitution (Application f x) (Application g y) = do
      next <- go substitution f g
      go next x y
    go substitution a b
      | a == b = Right substitution
      | otherwise = Left (TypesDiffer a b)

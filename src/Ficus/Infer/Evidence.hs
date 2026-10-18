module Ficus.Infer.Evidence (EvidenceFailure (..), solvePredicate) where

import Control.Monad (forM)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Infer.Declaration
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Infer.Unify qualified as U
import Ficus.Syntax.Core qualified as C
import Ficus.Type
import Ficus.Type.Substitution qualified as S

data EvidenceFailure = NoEvidence | MultipleEvidence | CyclicEvidence deriving (Eq, Show)

solvePredicate :: Declarations -> [(Predicate InferType, Evidence)] -> Predicate InferType -> Infer (Either EvidenceFailure Evidence)
solvePredicate environment givens = solve Set.empty
  where
    available = concatMap (superclasses Set.empty) givens
    superclasses visited entry@(predicate, evidence)
      | predicate `Set.member` visited = []
      | otherwise =
          entry
            : concat
              [ superclasses (Set.insert predicate visited) (fmap (S.apply mapping) parent, SuperclassEvidence (predicateTrait predicate) index evidence)
              | Just traitNode <- [Map.lookup (predicateTrait predicate) (traitDeclarations environment)],
                let trait = C.nodeValue traitNode,
                let mapping = binderSubstitution [traitParameter trait] [predicateArgument predicate],
                (index, parent) <- zip [0 ..] (traitSuperclasses trait)
              ]
    solve visited wanted = case [proof | (given, proof) <- available, given == wanted] of
      proof : _ -> pure (Right proof)
      [] | wanted `Set.member` visited -> pure (Left CyclicEvidence)
      [] -> do
        matches <- fmap concat $ forM (Map.toAscList (implementationDeclarations environment)) $ \(ident, node) -> do
          let implementation = C.nodeValue node
              head' = implementationHead implementation
          if predicateTrait head' /= predicateTrait wanted
            then pure []
            else do
              (headType, predicates, arguments) <- instantiate (C.nodeSpan node) (Scheme [] (implementationParameters implementation) (implementationContext implementation) (predicateArgument head'))
              pure $ case U.match headType (predicateArgument wanted) of
                Left _ -> []
                Right mapping -> [(ident, map (S.apply mapping) arguments, map (fmap (S.apply mapping)) predicates)]
        case matches of
          [] -> pure (Left NoEvidence)
          [(ident, arguments, predicates)] -> do
            proofs <- mapM (solve (Set.insert wanted visited)) predicates
            pure (ImplementationEvidence ident arguments <$> sequence proofs)
          _ -> pure (Left MultipleEvidence)

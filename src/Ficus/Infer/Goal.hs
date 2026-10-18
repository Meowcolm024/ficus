module Ficus.Infer.Goal (prepareGoals, reportGoals) where

import Control.Monad (forM_, unless)
import Control.Monad.State.Strict (gets, modify')
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Ficus.Error.Type qualified as E
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name (HoleId, NodeId (..))
import Ficus.Type
import Ficus.Util.Source (Provenance (..))

-- Snapshot obligations while their inference identities still match the hole.
-- Lowering later applies the enclosing binding's abstraction to this snapshot.
prepareGoals :: [Wanted] -> Infer ()
prepareGoals residual = do
  fields <- Infer (gets pendingFields)
  retained <- Infer (gets (concat . Map.elems . bindingWanteds))
  predicates <-
    mapM
      ( \wanted -> do
          argument <- zonk (predicateArgument (wantedPredicate wanted))
          pure (wantedOrigin wanted, "trait " <> renderConstructor (predicateTrait (wantedPredicate wanted)), argument)
      )
      (residual ++ retained)
  receivers <-
    mapM
      ( \field -> do
          receiver <- zonk (fieldReceiver field)
          pure (fieldOrigin field, "field " <> fieldName field, receiver)
      )
      fields
  goals <- Infer (gets checkedGoals)
  updated <- forMGoals (predicates ++ receivers) goals
  Infer (modify' (\s -> s {checkedGoals = updated}))
  where
    forMGoals obligations = traverse $ \node -> do
      ty <- zonk (C.goalType (C.nodeValue node))
      blockers <- mapM makeBlocker [(origin, message, pending) | (origin, message, pending) <- obligations, not (Set.null (freeVariables ty `Set.intersection` freeVariables pending))]
      pure (fmap (\goal -> goal {C.goalBlockers = blockers}) node)
    makeBlocker (origin, message, ty) = do
      ident <- freshId
      pure (C.Node (NodeId (-ident - 1)) origin (GeneratedOrigin "hole constraint" origin) (message, ty))

reportGoals :: Map HoleId (C.Node (C.HoleGoal InferType)) -> Infer ()
reportGoals goals = forM_ (sortOn C.nodeSpan (Map.elems goals)) $ \node -> do
  resolved <- traverse (traverse zonk) node
  let goal = C.nodeValue resolved
      context = [name <> " : " <> renderInferType (schemeType scheme) | entry <- C.goalContext goal, let (name, scheme) = C.nodeValue entry]
      blockers = [message <> " : " <> renderInferType ty | entry <- C.goalBlockers goal, let (message, ty) = C.nodeValue entry]
      details = (if null context then "" else "; in scope: " <> T.intercalate ", " context) <> (if null blockers then "" else "; blocked by: " <> T.intercalate ", " blockers)
      related = [(C.nodeSpan entry, fst (C.nodeValue entry)) | entry <- C.goalBlockers goal]
      diagnostic = (E.diagnostic E.ExpressionHole (C.nodeSpan node) ("expression hole has type " <> renderInferType (C.goalType goal) <> details)) {E.diagnosticRelated = related}
  reported <- Infer (gets (any (\d -> E.diagnosticCode d == E.ExpressionHole && E.diagnosticSpan d == C.nodeSpan node) . diagnostics))
  unless reported (emit diagnostic)

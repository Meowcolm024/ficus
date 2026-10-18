-- | The final inference-to-Core boundary. Zonk every embedded type before
-- reporting goals or attempting acceptance; errors retain diagnostic Core only.
module Ficus.Elaborate.Finalize (Finalization (..), finalizeModule) where

import Control.Monad.State.Strict (gets)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Goal
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate

data Finalization
  = Complete ValidatedCore [E.Diagnostic]
  | Incomplete (C.CoreModule C.CoreType) [E.Diagnostic]
  deriving (Eq, Show)

finalizeModule :: C.CoreModule InferType -> Infer Finalization
finalizeModule input = do
  finishWeakVariables
  resolved <- traverse zonk input
  let output = fmap (fmap closeVariable) resolved
      skolems = [v | ty <- foldr (:) [] resolved, v@(Skolem _) <- foldr (:) [] ty]
  if null skolems
    then pure ()
    else emit (E.diagnostic E.InvalidAnnotation (C.coreSpan input) "a rigid type variable escaped its signature scope")
  reportGoals (C.coreGoals resolved)
  errors <- Infer (gets diagnostics)
  if any ((== D.Error) . D.diagnosticSeverity . D.toDiagnostic) errors
    then pure (Incomplete output errors)
    else case acceptCore output of
      Right accepted -> pure (Complete accepted errors)
      Left failures -> do
        mapM_ emit failures
        pure (Incomplete output (errors ++ failures))
  where
    closeVariable (Bound ident) = C.BoundVariable ident
    closeVariable (Meta (MetaId ident)) = C.DiagnosticVariable (C.DiagnosticMetaId ident)
    closeVariable (Skolem (SkolemId ident)) = C.DiagnosticVariable (C.DiagnosticMetaId (-ident - 1))

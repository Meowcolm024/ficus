-- | Static backend diagnostics, separate from failures during evaluation.
module FicusBackend.Error where

import Data.Text (Text)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source

data ErrorKind = InvalidProgram | InvalidEntry | ExpressionHole | InvalidCore | InvalidLiteral | MissingGlobal
  deriving (Eq, Ord, Show)

data BackendError = BackendError {errorKind :: ErrorKind, errorSpan :: Span, errorMessage :: Text} deriving (Eq, Show)

runtimeSpan :: Span
runtimeSpan = Span "<runtime>" (Position 1 1 0) (Position 1 1 0)

instance D.ToDiagnostic BackendError where
  toDiagnostic failure = D.Diagnostic code D.Error (errorSpan failure) (errorMessage failure) Nothing []
    where
      code = case errorKind failure of
        InvalidProgram -> "R0099"
        InvalidEntry -> "R0101"
        InvalidLiteral -> "R0102"
        MissingGlobal -> "R0103"
        ExpressionHole -> "T0101"
        InvalidCore -> "T0099"

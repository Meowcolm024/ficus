module FicusBackend.Runtime.Error where

import Data.Text (Text)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source

data ErrorKind = MatchFailure | PrimitiveFailure | UninitializedRead | InvalidValue | InvalidProgram | InvalidEntry | ExpressionHole | InvalidCore | InvalidLiteral | MissingGlobal
  deriving (Eq, Ord, Show)

data RuntimeError = RuntimeError {errorKind :: ErrorKind, errorSpan :: Span, errorMessage :: Text} deriving (Eq, Show)

instance D.ToDiagnostic RuntimeError where
  toDiagnostic failure = D.Diagnostic code D.Error (errorSpan failure) (errorMessage failure) Nothing []
    where
      code = case errorKind failure of
        MatchFailure -> "R0001"
        PrimitiveFailure -> "R0002"
        UninitializedRead -> "R0003"
        InvalidValue -> "R0004"
        InvalidProgram -> "R0099"
        InvalidEntry -> "R0101"
        InvalidLiteral -> "R0102"
        MissingGlobal -> "R0103"
        ExpressionHole -> "T0101"
        InvalidCore -> "T0099"

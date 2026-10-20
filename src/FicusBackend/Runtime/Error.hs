-- | Evaluation failures carry a message, with one code at the diagnostic boundary.
module FicusBackend.Runtime.Error where

import Data.Text (Text)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source

newtype RuntimeError = RuntimeError {errorMessage :: Text} deriving (Eq, Show)

instance D.ToDiagnostic RuntimeError where
  toDiagnostic failure = D.Diagnostic "R0001" D.Error origin (errorMessage failure) Nothing []
    where
      origin = Span "<runtime>" (Position 1 1 0) (Position 1 1 0)

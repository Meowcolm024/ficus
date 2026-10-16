-- | Common rendering interface. Phase modules retain their typed error codes.
module Ficus.Error.Diagnostic where

import Data.Text (Text)
import Ficus.Util.Source (Span)

data Severity = Error | Warning deriving (Eq, Ord, Show)

data Diagnostic = Diagnostic
  { diagnosticCode :: Text,
    diagnosticSeverity :: Severity,
    diagnosticSpan :: Span,
    diagnosticMessage :: Text,
    diagnosticIdentity :: Maybe Int,
    diagnosticRelated :: [(Span, Text)]
  }
  deriving (Eq, Show)

class ToDiagnostic a where
  toDiagnostic :: a -> Diagnostic

instance ToDiagnostic Diagnostic where
  toDiagnostic = id

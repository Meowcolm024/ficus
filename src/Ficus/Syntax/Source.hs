module Ficus.Syntax.Source where

import Data.Text (Text)
import Data.Text qualified as T
import Text.Megaparsec (ShowErrorComponent (..))

-- End positions are inclusive; an EOF span is zero-width.
data Position = Position {line :: Int, column :: Int, offset :: Int}
  deriving (Eq, Ord, Show)

data Span = Span {sourceFile :: FilePath, start :: Position, end :: Position}
  deriving (Eq, Ord, Show)

newtype Provenance = SourceOrigin Span deriving (Eq, Show)

data TokenKind
  = Lower
  | Upper
  | Keyword
  | Symbol
  | Punctuation
  | NumberLiteral
  | CharacterLiteral
  | StringLiteral
  | PragmaName
  deriving (Eq, Ord, Show)

data Token = Token {tokenKind :: TokenKind, tokenText :: Text, tokenSpan :: Span}
  deriving (Eq, Ord, Show)

data Comment = Comment {commentText :: Text, commentSpan :: Span}
  deriving (Eq, Show)

data DiagnosticKind = LexicalError | LayoutError | SyntaxError
  deriving (Eq, Ord, Show)

data Diagnostic = Diagnostic
  {diagnosticKind :: DiagnosticKind, primarySpan :: Span, diagnosticMessage :: Text}
  deriving (Eq, Ord, Show)

instance ShowErrorComponent Diagnostic where
  showErrorComponent = T.unpack . diagnosticMessage

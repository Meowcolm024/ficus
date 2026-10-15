module Ficus.Syntax.Token (TokenKind (..), Token (..)) where

import Data.Text (Text)
import Ficus.Util.Source (Span)

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

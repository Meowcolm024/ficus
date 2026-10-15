module Ficus.Util.Source
  ( Position (..),
    Span (..),
    Provenance (..),
    Comment (..),
    tabWidth,
    sourceEndSpan,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- End positions are inclusive; an EOF span is zero-width. Offsets count source
-- characters; columns use the parser's four-column tab stops.
data Position = Position {line :: Int, column :: Int, offset :: Int}
  deriving (Eq, Ord, Show)

data Span = Span {sourceFile :: FilePath, start :: Position, end :: Position}
  deriving (Eq, Ord, Show)

newtype Provenance = SourceOrigin Span deriving (Eq, Show)

data Comment = Comment {commentText :: Text, commentSpan :: Span}
  deriving (Eq, Show)

tabWidth :: Int
tabWidth = 4

sourceEndSpan :: FilePath -> Text -> Span
sourceEndSpan file source = Span file p p
  where
    p = T.foldl' advance (Position 1 1 0) source
    advance pos c = case c of
      '\n' -> Position (line pos + 1) 1 (offset pos + 1)
      '\t' -> pos {column = column pos + tabWidth - (column pos - 1) `mod` tabWidth, offset = offset pos + 1}
      _ -> pos {column = column pos + 1, offset = offset pos + 1}

-- | Ficus offsets count Unicode code points; LSP positions count UTF-16 units.
-- Use offsets rather than parser columns, which also expand tabs.
module FicusLsp.Position (spanRange, offsetPosition, positionOffset, containsPosition, splitSpan) where

import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Util.Source qualified as S
import Language.LSP.Protocol.Types qualified as L

width :: Char -> Int
width c = if ord c > 0xffff then 2 else 1

offsetPosition :: Text -> Int -> L.Position
offsetPosition source offset =
  let (line, column) = T.foldl' step (0, 0) (T.take (max 0 offset) source)
   in L.Position (fromIntegral line) (fromIntegral column)
  where
    step :: (Int, Int) -> Char -> (Int, Int)
    step (line, column) c = if c == '\n' then (line + 1, 0) else (line, column + width c)

positionOffset :: Text -> L.Position -> Maybe Int
positionOffset source (L.Position wantedLine wantedColumn) = go 0 0 0 (T.unpack source)
  where
    go :: Int -> Int -> Int -> [Char] -> Maybe Int
    go line column offset rest
      | line == fromIntegral wantedLine && column == fromIntegral wantedColumn = Just offset
      | line > fromIntegral wantedLine || (line == fromIntegral wantedLine && column > fromIntegral wantedColumn) = Nothing
      | otherwise = case rest of
          [] -> Nothing
          c : cs
            | c == '\n' -> go (line + 1) 0 (offset + 1) cs
            | otherwise -> go line (column + width c) (offset + 1) cs

spanRange :: Text -> S.Span -> L.Range
spanRange source location = L.Range (offsetPosition source first) (offsetPosition source after)
  where
    first = S.offset (S.start location)
    after = min (T.length source) (S.offset (S.end location) + 1)

containsPosition :: Text -> S.Span -> L.Position -> Bool
containsPosition source location position = case positionOffset source position of
  Just offset -> S.offset (S.start location) <= offset && offset <= S.offset (S.end location) && offset < T.length source
  Nothing -> False

-- Semantic tokens are split into nonempty single-line ranges. Newlines and
-- CRLF terminators are never included in a token's encoded length.
splitSpan :: Text -> S.Span -> [(L.UInt, L.UInt, L.UInt)]
splitSpan source location = go first (T.splitOn "\n" text)
  where
    first = S.offset (S.start location)
    text = T.take (S.offset (S.end location) - first + 1) (T.drop first source)
    go _ [] = []
    go offset (part : rest) =
      let L.Position line column = offsetPosition source offset
          size = fromIntegral (T.foldl' (\n c -> n + width c) 0 (T.dropWhileEnd (== '\r') part))
       in [(line, column, size) | size > 0] ++ go (offset + T.length part + 1) rest

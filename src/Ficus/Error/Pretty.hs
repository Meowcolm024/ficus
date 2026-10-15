-- | Render a diagnostic against the source text that its span references.
module Ficus.Error.Pretty (prettyDiagnostic) where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Parser
import Ficus.Util.Source
import Text.PrettyPrint qualified as P

-- | No source is read from disk. Callers supply the exact text they parsed,
-- which also permits diagnostics for stdin and unsaved editor buffers.
-- Columns count Unicode characters, with four-column tab stops, as in parsing.
prettyDiagnostic :: Text -> Diagnostic -> Text
prettyDiagnostic source diagnostic = T.pack (P.render (P.vcat (map (P.text . T.unpack) output)))
  where
    s = primarySpan diagnostic
    firstLine = line (start s)
    lastLine = line (end s)
    header =
      T.pack (sourceFile s)
        <> ":"
        <> number firstLine
        <> ":"
        <> number (column (start s))
        <> ": error["
        <> renderParserErrorCode (diagnosticCode diagnostic)
        <> "]: "
        <> diagnosticMessage diagnostic
    referenced =
      [ (n, expandTabs (T.dropWhileEnd (== '\r') t))
      | (n, t) <- zip [1 ..] (T.splitOn "\n" source),
        n >= firstLine,
        n <= lastLine
      ]
    gutterWidth = case reverse referenced of
      (n, _) : _ -> T.length (number n)
      [] -> 1
    gutter = T.replicate gutterWidth " " <> " |"
    output =
      header : case referenced of
        [] -> []
        _ -> gutter : excerpt referenced
    excerpt rows
      | length rows <= 4 = concatMap renderLine rows
      | otherwise =
          concatMap renderLine (take 2 rows)
            ++ [gutter <> " ..."]
            ++ case reverse rows of
              final : _ -> renderLine final
              [] -> []
    renderLine (n, text) =
      let sourceWidth = T.length text
          requestedStart = if n == firstLine then column (start s) else 1
          from = max 1 (min (sourceWidth + 1) requestedStart)
          requestedEnd = if n == lastLine then column (end s) else sourceWidth
          to = max from (min sourceWidth requestedEnd)
          label = T.justifyRight gutterWidth ' ' (number n)
       in [ label <> " | " <> text,
            gutter <> " " <> T.replicate (from - 1) " " <> T.replicate (to - from + 1) "^"
          ]
    number = T.pack . show

expandTabs :: Text -> Text
expandTabs text = T.concat (reverse parts)
  where
    (_, parts) = T.foldl' step (1, []) text
    step (col, chunks) c
      | c == '\t' =
          let width = tabWidth - (col - 1) `mod` tabWidth
           in (col + width, T.replicate width " " : chunks)
      | otherwise = (col + 1, T.singleton c : chunks)

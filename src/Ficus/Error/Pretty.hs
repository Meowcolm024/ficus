-- | Render a diagnostic against the source text that its span references.
module Ficus.Error.Pretty (prettyDiagnostic, prettyDiagnosticRelativeTo) where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Diagnostic
import Ficus.Util.Source
import System.FilePath (equalFilePath, isAbsolute, joinPath, normalise, splitDirectories, takeDrive)
import Text.PrettyPrint qualified as P

-- | Render source locations relative to an absolute working directory. Paths
-- embedded in diagnostic messages are deliberately left unchanged.
prettyDiagnosticRelativeTo :: (ToDiagnostic d) => FilePath -> Text -> d -> Text
prettyDiagnosticRelativeTo directory = prettyDiagnosticWithPath (relativeSourcePath directory)

-- | No source is read from disk. Callers supply the exact text they parsed,
-- which also permits diagnostics for stdin and unsaved editor buffers.
-- Columns count Unicode characters, with four-column tab stops, as in parsing.
prettyDiagnostic :: (ToDiagnostic d) => Text -> d -> Text
prettyDiagnostic = prettyDiagnosticWithPath id

prettyDiagnosticWithPath :: (ToDiagnostic d) => (FilePath -> FilePath) -> Text -> d -> Text
prettyDiagnosticWithPath displayPath source input = T.pack (P.render (P.vcat (map (P.text . T.unpack) output)))
  where
    diagnostic = toDiagnostic input
    s = diagnosticSpan diagnostic
    firstLine = line (start s)
    lastLine = line (end s)
    header =
      T.pack (displayPath (sourceFile s))
        <> ":"
        <> number firstLine
        <> ":"
        <> number (column (start s))
        <> ": "
        <> (case diagnosticSeverity diagnostic of Error -> "error"; Warning -> "warning")
        <> "["
        <> diagnosticCode diagnostic
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
      ( header : case referenced of
          [] -> []
          _ -> gutter : excerpt referenced
      )
        ++ ["note: " <> T.pack (displayPath (sourceFile span')) <> ":" <> number (line (start span')) <> ":" <> number (column (start span')) <> ": " <> label | (span', label) <- diagnosticRelated diagnostic]
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

relativeSourcePath :: FilePath -> FilePath -> FilePath
relativeSourcePath directory file
  | not (isAbsolute directory && isAbsolute file) = file
  | not (equalFilePath (takeDrive directory) (takeDrive file)) = file
  | otherwise =
      let (parents, children) = removeCommon (splitDirectories (normalise directory)) (splitDirectories (normalise file))
          parts = replicate (length parents) ".." ++ children
       in if null parts then "." else joinPath parts
  where
    removeCommon (a : as) (b : bs) | equalFilePath a b = removeCommon as bs
    removeCommon as bs = (as, bs)

expandTabs :: Text -> Text
expandTabs text = T.concat (reverse parts)
  where
    (_, parts) = T.foldl' step (1, []) text
    step (col, chunks) c
      | c == '\t' =
          let width = tabWidth - (col - 1) `mod` tabWidth
           in (col + width, T.replicate width " " : chunks)
      | otherwise = (col + 1, T.singleton c : chunks)

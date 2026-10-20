-- | Render a diagnostic against the source text that its span references.
module Ficus.Error.Pretty
  ( DiagnosticStyle (..),
    prettyDiagnostic,
    prettyDiagnosticRelativeTo,
    prettyDiagnosticWithOptionalSourceRelativeTo,
    prettyDiagnosticWithStyleRelativeTo,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Diagnostic
import Ficus.Util.Source
import System.Console.ANSI (Color (..), ColorIntensity (..), ConsoleIntensity (..), ConsoleLayer (..), SGR (..), setSGRCode)
import System.FilePath (equalFilePath, isAbsolute, joinPath, normalise, splitDirectories, takeDrive)
import Text.PrettyPrint qualified as P

data DiagnosticStyle = Plain | Ansi deriving (Eq, Show)

-- | Render source locations relative to an absolute working directory. Paths
-- embedded in diagnostic messages are deliberately left unchanged.
prettyDiagnosticRelativeTo :: (ToDiagnostic d) => FilePath -> Text -> d -> Text
prettyDiagnosticRelativeTo directory source = prettyDiagnosticWithOptionalSourceRelativeTo directory (Just source)

-- | Omit the excerpt when no source was loaded. An available empty source still
-- has an EOF position and receives a caret.
prettyDiagnosticWithOptionalSourceRelativeTo :: (ToDiagnostic d) => FilePath -> Maybe Text -> d -> Text
prettyDiagnosticWithOptionalSourceRelativeTo = prettyDiagnosticWithStyleRelativeTo Plain

-- | Styling is explicit; terminal capability detection belongs to the caller.
-- Source text and messages remain unstyled, keeping excerpts readable verbatim.
prettyDiagnosticWithStyleRelativeTo :: (ToDiagnostic d) => DiagnosticStyle -> FilePath -> Maybe Text -> d -> Text
prettyDiagnosticWithStyleRelativeTo style directory = prettyDiagnosticWithPath style (relativeSourcePath directory)

-- | No source is read from disk. Callers supply the exact text they parsed,
-- which also permits diagnostics for stdin and unsaved editor buffers.
-- Columns count Unicode characters, with four-column tab stops, as in parsing.
prettyDiagnostic :: (ToDiagnostic d) => Text -> d -> Text
prettyDiagnostic source = prettyDiagnosticWithPath Plain id (Just source)

prettyDiagnosticWithPath :: (ToDiagnostic d) => DiagnosticStyle -> (FilePath -> FilePath) -> Maybe Text -> d -> Text
prettyDiagnosticWithPath style displayPath source input = T.pack (P.render (P.vcat (map (P.text . T.unpack) output)))
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
        <> severityColor ((case diagnosticSeverity diagnostic of Error -> "error"; Warning -> "warning") <> "[" <> diagnosticCode diagnostic <> "]")
        <> ": "
        <> diagnosticMessage diagnostic
    referenced =
      [ (n, expandTabs (T.dropWhileEnd (== '\r') t))
      | text <- maybe [] pure source,
        (n, t) <- zip [1 ..] (T.splitOn "\n" text),
        n >= firstLine,
        n <= lastLine
      ]
    gutterWidth = case reverse referenced of
      (n, _) : _ -> T.length (number n)
      [] -> 1
    gutter = color [SetColor Foreground Dull Cyan] (T.replicate gutterWidth " " <> " |")
    output =
      ( header : case referenced of
          [] -> []
          _ -> gutter : excerpt referenced
      )
        ++ [color [SetConsoleIntensity BoldIntensity, SetColor Foreground Dull Cyan] "note" <> ": " <> T.pack (displayPath (sourceFile span')) <> ":" <> number (line (start span')) <> ":" <> number (column (start span')) <> ": " <> label | (span', label) <- diagnosticRelated diagnostic]
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
       in [ color [SetColor Foreground Dull Cyan] (label <> " |") <> " " <> text,
            gutter <> " " <> T.replicate (from - 1) " " <> severityColor (T.replicate (to - from + 1) "^")
          ]
    severityColor = color [SetConsoleIntensity BoldIntensity, SetColor Foreground Dull (case diagnosticSeverity diagnostic of Error -> Red; Warning -> Yellow)]
    color rendition text = case style of Plain -> text; Ansi -> T.pack (setSGRCode rendition) <> text <> T.pack (setSGRCode [Reset])
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

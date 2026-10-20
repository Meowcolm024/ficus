module FicusLsp.Protocol (diagnostic, hoverAt, definitionAt, semanticTokens) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source qualified as S
import FicusLsp.Index qualified as I
import FicusLsp.Position
import Language.LSP.Protocol.Types qualified as L

diagnostic :: Map FilePath Text -> D.Diagnostic -> L.Diagnostic
diagnostic sources problem =
  L.Diagnostic
    (range (D.diagnosticSpan problem))
    (Just (case D.diagnosticSeverity problem of D.Error -> L.DiagnosticSeverity_Error; D.Warning -> L.DiagnosticSeverity_Warning))
    (Just (L.InR (D.diagnosticCode problem)))
    Nothing
    (Just "ficus")
    (D.diagnosticMessage problem)
    Nothing
    (Just [L.DiagnosticRelatedInformation (L.Location (L.filePathToUri (S.sourceFile location)) (range location)) message | (location, message) <- D.diagnosticRelated problem])
    Nothing
  where
    range location = spanRange (Map.findWithDefault "" (S.sourceFile location) sources) location

symbolAt :: Text -> [I.Symbol] -> L.Position -> Maybe I.Symbol
symbolAt source symbols position = case sortOn priority [symbol | symbol <- symbols, containsPosition source (I.symbolSpan symbol) position] of
  symbol : _ -> Just symbol
  [] -> Nothing
  where
    priority symbol = let location = I.symbolSpan symbol in (S.offset (S.end location) - S.offset (S.start location), not (I.symbolDeclared symbol))

hoverAt :: Text -> [I.Symbol] -> L.Position -> Maybe L.Hover
hoverAt source symbols position = do
  symbol <- symbolAt source symbols position
  ty <- I.symbolType symbol
  pure (L.Hover (L.InL (L.mkMarkdown ("```ficus\n" <> I.symbolName symbol <> " : " <> ty <> "\n```"))) (Just (spanRange source (I.symbolSpan symbol))))

definitionAt :: Map FilePath Text -> Text -> [I.Symbol] -> L.Position -> Maybe L.Location
definitionAt sources source symbols position = do
  symbol <- symbolAt source symbols position
  location <- I.symbolDefinition symbol
  text <- Map.lookup (S.sourceFile location) sources
  pure (L.Location (L.filePathToUri (S.sourceFile location)) (spanRange text location))

semanticTokens :: FilePath -> Text -> [I.Symbol] -> Either Text L.SemanticTokens
semanticTokens file source symbols =
  L.makeSemanticTokens
    L.defaultSemanticTokensLegend
    [ L.SemanticTokenAbsolute line column size (tokenClass kind) [L.SemanticTokenModifiers_Declaration | declared]
    | (location, kind, declared) <- I.semanticSpans file source symbols,
      (line, column, size) <- splitSpan source location
    ]

tokenClass :: I.TokenClass -> L.SemanticTokenTypes
tokenClass kind = case kind of
  I.Namespace -> L.SemanticTokenTypes_Namespace
  I.TypeName -> L.SemanticTokenTypes_Type
  I.TypeParameter -> L.SemanticTokenTypes_TypeParameter
  I.Parameter -> L.SemanticTokenTypes_Parameter
  I.Variable -> L.SemanticTokenTypes_Variable
  I.Function -> L.SemanticTokenTypes_Function
  I.Property -> L.SemanticTokenTypes_Property
  I.Constructor -> L.SemanticTokenTypes_EnumMember
  I.Trait -> L.SemanticTokenTypes_Interface
  I.Keyword -> L.SemanticTokenTypes_Keyword
  I.Operator -> L.SemanticTokenTypes_Operator
  I.Number -> L.SemanticTokenTypes_Number
  I.String -> L.SemanticTokenTypes_String
  I.Comment -> L.SemanticTokenTypes_Comment
  I.Pragma -> L.SemanticTokenTypes_Macro

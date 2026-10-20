module FicusLsp.Protocol (diagnostic, hoverAt, definitionAt, documentSymbols, flatDocumentSymbols, semanticTokens) where

import Control.Lens ((^.))
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Diagnostic qualified as D
import Ficus.Syntax.Concrete qualified as Concrete
import Ficus.Syntax.Parser (parseModule)
import Ficus.Util.Source qualified as S
import FicusLsp.Index qualified as I
import FicusLsp.Position
import Language.LSP.Protocol.Lens qualified as L
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

data DeclarationKey = ValueDeclaration Text | TypeDeclaration Text | InstanceDeclaration Int
  deriving (Eq, Ord)

-- Read only top-level syntax and type/trait member blocks. Function bodies and
-- where clauses deliberately do not contribute entries to the outline.
documentSymbols :: FilePath -> Text -> [I.Symbol] -> [L.DocumentSymbol]
documentSymbols file source symbols = case parseModule file source of
  Left _ -> []
  Right tree -> ordered (map importSymbol (Concrete.moduleImports tree) ++ declarations False (Concrete.moduleDeclarations tree))
  where
    ordered = sortOn (\symbol -> symbol ^. L.range . L.start)
    cover a b = a {S.start = min (S.start a) (S.start b), S.end = max (S.end a) (S.end b)}
    slice location = T.take (S.offset (S.end location) - S.offset (S.start location) + 1) (T.drop (S.offset (S.start location)) source)
    named method fallback location name children =
      let matching = find (\symbol -> I.symbolDeclared symbol && I.within (Concrete.nameLocation name) (I.symbolSpan symbol)) symbols
          detail = matching >>= I.symbolType
          role = matching >>= I.symbolClass >>= symbolKind
          kind = if method && fallback `elem` [L.SymbolKind_Function, L.SymbolKind_Variable] then L.SymbolKind_Method else maybe fallback id role
       in L.DocumentSymbol (Concrete.nameText name) detail kind Nothing Nothing (spanRange source location) (spanRange source (Concrete.nameLocation name)) (Just children)
    declarations methods items = ordered (mapMaybe (renderGroup methods) (Map.elems (Map.fromListWith (flip (++)) [(key, [item]) | item <- items, Just key <- [keyFor item]])))
    renderGroup _ [] = Nothing
    renderGroup methods items@(first : rest) =
      let location = foldl (\region item -> cover region (Concrete.location item)) (Concrete.location first) rest
          representative = maybe first id (find hasBody items)
          withName fallback name children = Just (named methods fallback location (maybe name id (nameOf first)) children)
       in case Concrete.concrete representative of
            Concrete.TypeSignature name _ -> withName L.SymbolKind_Variable name []
            Concrete.KindSignature name _ -> withName L.SymbolKind_Class name []
            Concrete.FunctionClause name _ parameters _ _ -> withName (if null parameters then L.SymbolKind_Variable else L.SymbolKind_Function) name []
            Concrete.TypeAlias name _ _ -> withName L.SymbolKind_Class name []
            Concrete.DataDeclaration name _ body ->
              withName
                L.SymbolKind_Class
                name
                ( case body of
                    Concrete.Constructors block -> [named False L.SymbolKind_EnumMember (Concrete.location item) constructor [] | item <- Concrete.blockItems block, let Concrete.Constructor constructor _ = Concrete.concrete item]
                    Concrete.Fields block -> [named False L.SymbolKind_Field (Concrete.location item) field [] | item <- Concrete.blockItems block, let Concrete.FieldSignature field _ = Concrete.concrete item]
                )
            Concrete.TraitDeclaration _ name _ block -> withName L.SymbolKind_Interface name (declarations True (Concrete.blockItems block))
            Concrete.Implementation _ target block -> Just (L.DocumentSymbol ("impl " <> slice (Concrete.location target)) Nothing L.SymbolKind_Object Nothing Nothing (spanRange source location) (spanRange source (Concrete.location target)) (Just (declarations True (Concrete.blockItems block))))
            Concrete.PatternBinding {} -> Nothing
            Concrete.PragmaDeclaration _ -> Nothing
    hasBody item = case Concrete.concrete item of
      Concrete.TypeSignature {} -> False
      Concrete.KindSignature {} -> False
      _ -> True
    nameOf item = case Concrete.concrete item of
      Concrete.TypeSignature name _ -> Just name
      Concrete.KindSignature name _ -> Just name
      Concrete.FunctionClause name _ _ _ _ -> Just name
      Concrete.TypeAlias name _ _ -> Just name
      Concrete.DataDeclaration name _ _ -> Just name
      Concrete.TraitDeclaration _ name _ _ -> Just name
      Concrete.Implementation {} -> Nothing
      Concrete.PatternBinding {} -> Nothing
      Concrete.PragmaDeclaration _ -> Nothing
    keyFor item = case Concrete.concrete item of
      Concrete.TypeSignature name _ -> Just (ValueDeclaration (Concrete.nameText name))
      Concrete.FunctionClause name _ _ _ _ -> Just (ValueDeclaration (Concrete.nameText name))
      Concrete.KindSignature name _ -> Just (TypeDeclaration (Concrete.nameText name))
      Concrete.TypeAlias name _ _ -> Just (TypeDeclaration (Concrete.nameText name))
      Concrete.DataDeclaration name _ _ -> Just (TypeDeclaration (Concrete.nameText name))
      Concrete.TraitDeclaration _ name _ _ -> Just (TypeDeclaration (Concrete.nameText name))
      Concrete.Implementation {} -> Just (InstanceDeclaration (S.offset (S.start (Concrete.location item))))
      Concrete.PatternBinding {} -> Nothing
      Concrete.PragmaDeclaration _ -> Nothing
    importSymbol item =
      let Concrete.Import path mode = Concrete.concrete item
          moduleName = T.intercalate "." (map Concrete.nameText path)
          name = moduleName <> case mode of Concrete.Aliased alias -> " as " <> Concrete.nameText alias; _ -> ""
          selection = case path of first : rest -> foldl (\region part -> cover region (Concrete.nameLocation part)) (Concrete.nameLocation first) rest; [] -> Concrete.location item
       in L.DocumentSymbol name Nothing L.SymbolKind_Module Nothing Nothing (spanRange source (Concrete.location item)) (spanRange source selection) (Just [])

-- Older clients still receive explicit container names in their flat response.
flatDocumentSymbols :: FilePath -> [L.DocumentSymbol] -> [L.SymbolInformation]
flatDocumentSymbols file = descend Nothing
  where
    descend container = concatMap (\(L.DocumentSymbol name _ kind tags deprecated _ selection children) -> L.SymbolInformation name kind tags container deprecated (L.Location (L.filePathToUri file) selection) : descend (Just name) (maybe [] id children))

symbolKind :: I.TokenClass -> Maybe L.SymbolKind
symbolKind role = case role of
  I.Namespace -> Just L.SymbolKind_Namespace
  I.TypeName -> Just L.SymbolKind_Class
  I.Variable -> Just L.SymbolKind_Variable
  I.Function -> Just L.SymbolKind_Function
  I.Property -> Just L.SymbolKind_Field
  I.Constructor -> Just L.SymbolKind_EnumMember
  I.Trait -> Just L.SymbolKind_Interface
  I.TypeParameter -> Nothing
  I.Parameter -> Nothing
  I.Keyword -> Nothing
  I.Operator -> Nothing
  I.Number -> Nothing
  I.String -> Nothing
  I.Comment -> Nothing
  I.Pragma -> Nothing

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

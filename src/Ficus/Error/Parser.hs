-- | Stable diagnostics for lexing, layout and parsing. Public codes use P and
-- four digits; name resolution and type checking will use N and T respectively.
-- Code strings are explicit, never derived from constructor order or wording.
module Ficus.Error.Parser
  ( ParserErrorCode (..),
    renderParserErrorCode,
    parserErrorKind,
    DiagnosticKind (..),
    Diagnostic (..),
    diagnosticKind,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source (Span)
import Text.Megaparsec (ShowErrorComponent (..))

data ParserErrorCode
  = UnexpectedToken
  | InvalidSyntax
  | InvalidDeclarationHead
  | MixedAssociativity
  | EmptyBlock
  | ExpectedBlock
  | InvalidPragmaArguments
  | InvalidImport
  | MixedTypeBody
  | MissingFinalExpression
  | InvalidModuleName
  | MissingBinder
  | InvalidConcreteTree
  | InsufficientIndentation
  | InvalidLayoutContinuation
  | InvalidSourceCharacter
  | InvalidPragmaName
  | UnterminatedPragma
  | UnterminatedBlockComment
  | UnterminatedLiteral
  | InvalidEscape
  | InvalidCharacterLiteral
  | InvalidInterpolation
  | UnmatchedInterpolationBrace
  deriving (Eq, Ord, Show, Enum, Bounded)

renderParserErrorCode :: ParserErrorCode -> Text
renderParserErrorCode = \case
  UnexpectedToken -> "P0001"
  InvalidSyntax -> "P0002"
  InvalidDeclarationHead -> "P0003"
  MixedAssociativity -> "P0004"
  EmptyBlock -> "P0005"
  ExpectedBlock -> "P0006"
  InvalidPragmaArguments -> "P0007"
  InvalidImport -> "P0008"
  MixedTypeBody -> "P0009"
  MissingFinalExpression -> "P0010"
  InvalidModuleName -> "P0011"
  MissingBinder -> "P0012"
  InvalidConcreteTree -> "P0099"
  InsufficientIndentation -> "P0101"
  InvalidLayoutContinuation -> "P0102"
  InvalidSourceCharacter -> "P0201"
  InvalidPragmaName -> "P0202"
  UnterminatedPragma -> "P0203"
  UnterminatedBlockComment -> "P0204"
  UnterminatedLiteral -> "P0205"
  InvalidEscape -> "P0206"
  InvalidCharacterLiteral -> "P0207"
  InvalidInterpolation -> "P0208"
  UnmatchedInterpolationBrace -> "P0209"

data DiagnosticKind = LexicalError | LayoutError | SyntaxError
  deriving (Eq, Ord, Show)

parserErrorKind :: ParserErrorCode -> DiagnosticKind
parserErrorKind = \case
  UnexpectedToken -> SyntaxError
  InvalidSyntax -> SyntaxError
  InvalidDeclarationHead -> SyntaxError
  MixedAssociativity -> SyntaxError
  EmptyBlock -> SyntaxError
  ExpectedBlock -> SyntaxError
  InvalidPragmaArguments -> SyntaxError
  InvalidImport -> SyntaxError
  MixedTypeBody -> SyntaxError
  MissingFinalExpression -> SyntaxError
  InvalidModuleName -> SyntaxError
  MissingBinder -> SyntaxError
  InvalidConcreteTree -> SyntaxError
  InsufficientIndentation -> LayoutError
  InvalidLayoutContinuation -> LayoutError
  InvalidSourceCharacter -> LexicalError
  InvalidPragmaName -> LexicalError
  UnterminatedPragma -> LexicalError
  UnterminatedBlockComment -> LexicalError
  UnterminatedLiteral -> LexicalError
  InvalidEscape -> LexicalError
  InvalidCharacterLiteral -> LexicalError
  InvalidInterpolation -> LexicalError
  UnmatchedInterpolationBrace -> LexicalError

data Diagnostic = Diagnostic
  {diagnosticCode :: ParserErrorCode, primarySpan :: Span, diagnosticMessage :: Text}
  deriving (Eq, Ord, Show)

diagnosticKind :: Diagnostic -> DiagnosticKind
diagnosticKind = parserErrorKind . diagnosticCode

instance ShowErrorComponent Diagnostic where
  showErrorComponent = T.unpack . diagnosticMessage

instance D.ToDiagnostic Diagnostic where
  toDiagnostic d = D.Diagnostic (renderParserErrorCode (diagnosticCode d)) D.Error (primarySpan d) (diagnosticMessage d) Nothing []

module Ficus.Error.Resolve where

import Data.Text (Text)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source (Span)

data ResolveCode
  = UnresolvedName
  | AmbiguousName
  | WrongNamespace
  | DuplicateDeclaration
  | DuplicatePatternBinder
  | ReservedName
  | InvalidTypeVariableScope
  | DuplicateSignature
  | MissingSignatureTarget
  | ClauseArityMismatch
  | InvalidAbstractTree
  | UnknownPragma
  | UnsupportedFeature
  | InvalidPragmaArguments
  | InvalidPragmaPlacement
  | InvalidPragmaTarget
  | UnknownBuiltin
  | ConflictingBuiltinAssociation
  | PreludeRequired
  | MissingSugarBinding
  | ModuleNotFound
  | InvalidModuleIdentity
  | ImportCycle
  | MissingExport
  | InvalidImportSelection
  | ModuleNotImportable
  | AmbiguousReexport
  | Shadowing
  | RepeatedModuleQualifier
  deriving (Eq, Ord, Show)

data Severity = Error | Warning deriving (Eq, Ord, Show)

data Diagnostic = Diagnostic {diagnosticId :: Int, diagnosticCode :: ResolveCode, severity :: Severity, primarySpan :: Span, diagnosticMessage :: Text, relatedSpans :: [(Span, Text)]} deriving (Eq, Show)

renderResolveCode :: ResolveCode -> Text
renderResolveCode = \case
  UnresolvedName -> "N0001"
  AmbiguousName -> "N0002"
  WrongNamespace -> "N0003"
  DuplicateDeclaration -> "N0004"
  DuplicatePatternBinder -> "N0005"
  ReservedName -> "N0006"
  InvalidTypeVariableScope -> "N0007"
  DuplicateSignature -> "N0010"
  MissingSignatureTarget -> "N0011"
  ClauseArityMismatch -> "N0012"
  InvalidAbstractTree -> "N0099"
  UnknownPragma -> "N0101"
  UnsupportedFeature -> "N0102"
  InvalidPragmaArguments -> "N0103"
  InvalidPragmaPlacement -> "N0104"
  InvalidPragmaTarget -> "N0105"
  UnknownBuiltin -> "N0111"
  ConflictingBuiltinAssociation -> "N0112"
  PreludeRequired -> "N0120"
  MissingSugarBinding -> "N0121"
  ModuleNotFound -> "N0201"
  InvalidModuleIdentity -> "N0202"
  ImportCycle -> "N0203"
  MissingExport -> "N0204"
  InvalidImportSelection -> "N0205"
  ModuleNotImportable -> "N0207"
  AmbiguousReexport -> "N0206"
  Shadowing -> "N0901"
  RepeatedModuleQualifier -> "N0902"

diagnostic :: ResolveCode -> Span -> Text -> Diagnostic
diagnostic code s msg = Diagnostic 0 code (if code `elem` [Shadowing, RepeatedModuleQualifier] then Warning else Error) s msg []

instance D.ToDiagnostic Diagnostic where
  toDiagnostic d = D.Diagnostic (renderResolveCode (diagnosticCode d)) (case severity d of Error -> D.Error; Warning -> D.Warning) (primarySpan d) (diagnosticMessage d) (Just (diagnosticId d)) (relatedSpans d)

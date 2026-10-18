module Ficus.Error.Type where

import Data.Text (Text)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source

data TypeCode
  = TypeMismatch
  | InfiniteType
  | KindMismatch
  | InvalidAnnotation
  | ExcessTypeArguments
  | TypeBinderMismatch
  | InvalidPatternAnnotation
  | CyclicAlias
  | UnsaturatedAlias
  | NonRegularData
  | InvalidCoreTree
  | ExpressionHole
  | UnresolvedWeakType
  | InvalidTypeHole
  | ExpansiveInitializer
  | UnsafeRecursiveInitialization
  | RefutablePattern
  | NonRecordReceiver
  | UnknownField
  | DuplicateField
  | MissingField
  | UnsatisfiedConstraint
  | AmbiguousConstraint
  | InvalidImplementation
  | InvalidTrait
  | CyclicSupertraits
  | OverlappingImplementations
  | RecursiveEvidence
  | OrphanImplementation
  | BuiltinContractMismatch
  | MissingBuiltinSignature
  | UnexpectedBuiltinDefinition
  | NonExhaustiveMatch
  | RedundantClause
  | KindDefaulting
  deriving (Eq, Ord, Show, Enum, Bounded)

renderTypeCode :: TypeCode -> Text
renderTypeCode = \case
  TypeMismatch -> "T0001"
  InfiniteType -> "T0002"
  KindMismatch -> "T0003"
  InvalidAnnotation -> "T0004"
  ExcessTypeArguments -> "T0005"
  TypeBinderMismatch -> "T0006"
  InvalidPatternAnnotation -> "T0007"
  CyclicAlias -> "T0008"
  UnsaturatedAlias -> "T0009"
  NonRegularData -> "T0010"
  InvalidCoreTree -> "T0099"
  ExpressionHole -> "T0101"
  UnresolvedWeakType -> "T0102"
  InvalidTypeHole -> "T0103"
  ExpansiveInitializer -> "T0201"
  UnsafeRecursiveInitialization -> "T0202"
  RefutablePattern -> "T0203"
  NonRecordReceiver -> "T0301"
  UnknownField -> "T0302"
  DuplicateField -> "T0303"
  MissingField -> "T0304"
  UnsatisfiedConstraint -> "T0401"
  AmbiguousConstraint -> "T0402"
  InvalidImplementation -> "T0403"
  InvalidTrait -> "T0404"
  CyclicSupertraits -> "T0405"
  OverlappingImplementations -> "T0406"
  RecursiveEvidence -> "T0407"
  OrphanImplementation -> "T0408"
  BuiltinContractMismatch -> "T0501"
  MissingBuiltinSignature -> "T0502"
  UnexpectedBuiltinDefinition -> "T0503"
  NonExhaustiveMatch -> "T0901"
  RedundantClause -> "T0902"
  KindDefaulting -> "T0903"

data Diagnostic = Diagnostic
  { diagnosticCode :: TypeCode,
    diagnosticSpan :: Span,
    diagnosticMessage :: Text,
    diagnosticRelated :: [(Span, Text)]
  }
  deriving (Eq, Show)

diagnostic :: TypeCode -> Span -> Text -> Diagnostic
diagnostic code span' message = Diagnostic code span' message []

instance D.ToDiagnostic Diagnostic where
  toDiagnostic d =
    D.Diagnostic
      (renderTypeCode (diagnosticCode d))
      (case diagnosticCode d of NonExhaustiveMatch -> D.Warning; RedundantClause -> D.Warning; KindDefaulting -> D.Warning; _ -> D.Error)
      (diagnosticSpan d)
      (diagnosticMessage d)
      Nothing
      (diagnosticRelated d)

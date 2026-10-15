module Ficus.Error.ParserSpec (tests) where

import Data.Set qualified as Set
import Data.Text.IO qualified as T
import Ficus.Error.Parser
import Ficus.Syntax.Parser (parseModule)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "parser error codes"
    [ testCase "public code registry is stable and complete" $ do
        map (\code -> (code, renderParserErrorCode code)) [minBound .. maxBound]
          @?= [ (UnexpectedToken, "P0001"),
                (InvalidSyntax, "P0002"),
                (InvalidDeclarationHead, "P0003"),
                (MixedAssociativity, "P0004"),
                (EmptyBlock, "P0005"),
                (ExpectedBlock, "P0006"),
                (InvalidPragmaArguments, "P0007"),
                (InvalidImport, "P0008"),
                (MixedTypeBody, "P0009"),
                (MissingFinalExpression, "P0010"),
                (InvalidModuleName, "P0011"),
                (MissingBinder, "P0012"),
                (InvalidConcreteTree, "P0099"),
                (InsufficientIndentation, "P0101"),
                (InvalidLayoutContinuation, "P0102"),
                (InvalidSourceCharacter, "P0201"),
                (InvalidPragmaName, "P0202"),
                (UnterminatedPragma, "P0203"),
                (UnterminatedBlockComment, "P0204"),
                (UnterminatedLiteral, "P0205"),
                (InvalidEscape, "P0206"),
                (InvalidCharacterLiteral, "P0207"),
                (InvalidInterpolation, "P0208"),
                (UnmatchedInterpolationBrace, "P0209")
              ],
      testCase "code strings are unique" $ do
        let codes = map renderParserErrorCode [minBound .. maxBound]
        Set.size (Set.fromList codes) @?= length codes,
      testGroup
        "fixture diagnostics select their own codes"
        [ testCase file $ do
            source <- T.readFile ("test/fixtures/parsing/negative/" <> file <> ".ficus")
            assertCode expected (parseModule file source)
        | (file, expected) <-
            [ ("BareAnnotatedLambda", UnexpectedToken),
              ("DotOperatorDeclaration", InvalidSyntax),
              ("InfixHeadLocal", InvalidDeclarationHead),
              ("MixedValueAssociativity", MixedAssociativity),
              ("EmptyDo", EmptyBlock),
              ("RecordWithMissingBlock", ExpectedBlock),
              ("PragmaAdjacentString", InvalidPragmaArguments),
              ("PubBareImport", InvalidImport),
              ("MixedTypeBody", MixedTypeBody),
              ("DeclarationOnlyBlock", MissingFinalExpression),
              ("SymbolicModuleInType", InvalidModuleName),
              ("DoNotIndented", InsufficientIndentation),
              ("DotAtItemBoundary", InvalidLayoutContinuation),
              ("LowerPragmaName", InvalidPragmaName),
              ("UnterminatedPragma", UnterminatedPragma),
              ("UnterminatedBlockComment", UnterminatedBlockComment),
              ("UnterminatedChar", UnterminatedLiteral),
              ("UnterminatedString", UnterminatedLiteral),
              ("InvalidEscape", InvalidEscape),
              ("MultipleCharacterLiteral", InvalidCharacterLiteral),
              ("InterpolationApplication", InvalidInterpolation),
              ("UnmatchedOpeningBrace", UnmatchedInterpolationBrace),
              ("UnmatchedClosingBrace", UnmatchedInterpolationBrace)
            ]
        ],
      testCase "invalid source character" $
        assertCode InvalidSourceCharacter (parseModule "Test.ficus" "f = `"),
      testCase "missing lambda binder" $
        assertCode MissingBinder (parseModule "Test.ficus" "f = -> 1")
    ]
  where
    assertCode expected = \case
      Left diagnostic -> diagnosticCode diagnostic @?= expected
      Right _ -> assertFailure "invalid source was accepted"

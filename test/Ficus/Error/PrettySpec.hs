module Ficus.Error.PrettySpec (tests) where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Parser
import Ficus.Error.Pretty (prettyDiagnostic, prettyDiagnosticRelativeTo)
import Ficus.Syntax.Parser (parseModule)
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "source-referenced diagnostics"
    [ testCase "source paths are relative without changing search paths" $ do
        let s = Span "/project/src/Main.ficus" (Position 1 1 0) (Position 1 1 0)
            d = D.Diagnostic "N0201" D.Error s "searched /project/library/Absent.ficus" Nothing [(s {sourceFile = "/project/library/Prelude.ficus"}, "dependency")]
            output = prettyDiagnosticRelativeTo "/project" "x" d
        assertBool "relative primary source path" ("src/Main.ficus:1:1:" `T.isPrefixOf` output)
        contains "note: library/Prelude.ficus:1:1:" output
        contains "searched /project/library/Absent.ficus" output
        assertBool "absolute source path omitted" (not ("/project/src/Main.ficus" `T.isInfixOf` output)),
      testCase "source paths outside the working directory use parent components" $ do
        let d = (diagnostic UnexpectedToken 1 1 1 1) {primarySpan = Span "/workspace/library/Prelude.ficus" (Position 1 1 0) (Position 1 1 0)}
        contains "../library/Prelude.ficus:1:1:" (prettyDiagnosticRelativeTo "/workspace/app" "x" d),
      testCase "relative and virtual source filenames remain unchanged" $ do
        let d = diagnostic UnexpectedToken 1 1 1 1
        contains "Demo.ficus:1:1:" (prettyDiagnosticRelativeTo "/project" "x" d)
        contains "<stdin>:1:1:" (prettyDiagnosticRelativeTo "/project" "x" (d {primarySpan = (primarySpan d) {sourceFile = "<stdin>"}})),
      testCase "header, source line and inclusive underline" $
        prettyDiagnostic "answer = nope\n" (diagnostic UnexpectedToken 1 10 1 13)
          @?= "Demo.ficus:1:10: error[P0001]: problem\n  |\n1 | answer = nope\n  |          ^^^^",
      testCase "four-column tab stops" $ do
        let output = prettyDiagnostic "\tbad\n" (diagnostic InvalidSyntax 1 5 1 7)
        contains "1 |     bad" output
        contains "  |     ^^^" output,
      testCase "Unicode columns match parser character positions" $ do
        let output = prettyDiagnostic "α β\n" (diagnostic InvalidSyntax 1 3 1 3)
        contains "1 | α β" output
        contains "  |   ^" output,
      testCase "multiline primary spans" $ do
        let output = prettyDiagnostic "first\nsecond\nthird\n" (diagnostic UnterminatedBlockComment 1 3 3 2)
        contains "1 | first\n  |   ^^^" output
        contains "2 | second\n  | ^^^^^^" output
        contains "3 | third\n  | ^^" output,
      testCase "long spans elide middle lines" $ do
        let output = prettyDiagnostic "a\nb\nc\nd\ne\nf\n" (diagnostic UnterminatedBlockComment 1 1 6 1)
        contains "  | ..." output
        contains "6 | f" output
        assertBool "omitted middle lines" (not ("3 |" `T.isInfixOf` output)),
      testCase "EOF after final newline has a visible caret" $ do
        let output = prettyDiagnostic "f =\n" (diagnostic UnexpectedToken 2 1 2 1)
        contains "2 | \n  | ^" output,
      testCase "unavailable source line leaves a useful header" $
        prettyDiagnostic "" (diagnostic UnexpectedToken 4 1 4 1)
          @?= "Demo.ficus:4:1: error[P0001]: problem",
      testCase "CRLF does not leak carriage returns into output" $ do
        let output = prettyDiagnostic "bad\r\n" (diagnostic InvalidSyntax 1 1 1 3)
        assertBool "no carriage returns" (not (T.any (== '\r') output))
        contains "1 | bad" output,
      testCase "EOF source utility uses four-column tabs" $ do
        let p = start (sourceEndSpan "Test.ficus" "\t")
        column p @?= 5
        offset p @?= 1,
      testCase "lexer spans and displayed tab expansion agree" $
        case parseModule "Demo.ficus" "\tf = \"\\q\"\n" of
          Left d -> do
            diagnosticCode d @?= InvalidEscape
            column (start (primarySpan d)) @?= 10
            contains "1 |     f = \"\\q\"" (prettyDiagnostic "\tf = \"\\q\"\n" d)
            contains "  |          ^^" (prettyDiagnostic "\tf = \"\\q\"\n" d)
          Right _ -> assertFailure "invalid escape accepted"
    ]
  where
    diagnostic code firstLine firstColumn lastLine lastColumn =
      Diagnostic code (Span "Demo.ficus" (Position firstLine firstColumn 0) (Position lastLine lastColumn 0)) "problem"
    contains :: Text -> Text -> Assertion
    contains wanted actual = assertBool ("missing " <> show wanted <> " in " <> show actual) (wanted `T.isInfixOf` actual)

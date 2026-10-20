module FicusLsp.Spec (tests) where

import Control.Exception (bracket)
import Control.Lens ((^.))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Ficus.Compile qualified as Compile
import Ficus.Error.Diagnostic qualified as D
import Ficus.Util.Source qualified as S
import FicusLsp.Index qualified as Index
import FicusLsp.Position
import FicusLsp.Protocol qualified as Protocol
import FicusLsp.ProtocolSpec qualified as Transport
import FicusLsp.Workspace
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Types qualified as L
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck qualified as QC

prefix :: Text
prefix = "{-# NO_IMPLICIT_PRELUDE #-}\n"

root :: FilePath
root = "/ficus-lsp-fixtures"

file :: FilePath
file = root <> "/Main.ficus"

checked :: [(FilePath, Text)] -> IO Analysis
checked documents = analyze (LspOptions [root] [] Nothing) (Map.fromList documents)

tests :: TestTree
tests =
  testGroup
    "LSP"
    [ Transport.tests,
      QC.testProperty "code-point offsets round trip through UTF-16 positions" $
        QC.forAll (QC.listOf (QC.elements ['a', 'α', '😀', '\t', '\n', '\r'])) $ \characters ->
          let source = T.pack characters in all (\offset -> positionOffset source (offsetPosition source offset) == Just offset) [0 .. length characters],
      testGroup
        "positions"
        [ testCase "tabs are one LSP unit and astral characters are two" $ do
            offsetPosition "\tα😀x\r\nz" 3 @?= L.Position 0 4
            offsetPosition "\tα😀x\r\nz" 6 @?= L.Position 1 0
            positionOffset "\tα😀x\r\nz" (L.Position 0 4) @?= Just 3,
          testCase "reject positions inside surrogate pairs and beyond the document" $ do
            positionOffset "😀x" (L.Position 0 1) @?= Nothing
            positionOffset "x" (L.Position 2 0) @?= Nothing,
          testCase "inclusive spans become exclusive UTF-16 ranges" $
            spanRange "😀x" (S.Span file (S.Position 1 1 0) (S.Position 1 1 0)) @?= L.Range (L.Position 0 0) (L.Position 0 2),
          testCase "EOF spans stay empty" $
            spanRange "x" (S.Span file (S.Position 1 2 1) (S.Position 1 2 1)) @?= L.Range (L.Position 0 1) (L.Position 0 1),
          testCase "multiline tokens exclude CRLF terminators" $
            splitSpan "a\r\n😀" (S.Span file (S.Position 1 1 0) (S.Position 2 1 3)) @?= [(0, 0, 1), (1, 0, 2)]
        ],
      testCase "unsaved imports support polymorphic hover and canonical definitions" $ do
        let library = root <> "/Library.ficus"
            source = prefix <> "use Library as Lib\ncheck () = Lib.identity 1\n"
        result <- checked [(file, source), (library, prefix <> "identity x = x\n")]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            position = L.Position 2 18
        case Protocol.hoverAt source index position of
          Nothing -> assertFailure "missing inferred hover"
          Just hover -> assertBool (show hover) ("identity : a -> a" `T.isInfixOf` hoverText hover)
        case Protocol.definitionAt (Compile.compileSources (compilation result)) source index position of
          Nothing -> assertFailure "missing definition"
          Just location -> do
            location ^. L.uri @?= L.filePathToUri library
            location ^. L.range @?= L.Range (L.Position 1 0) (L.Position 1 8),
      testCase "local shadowing jumps to the correct binder" $ do
        let source = prefix <> "check x = { x = 1; x }\n"
        result <- checked [(file, source)]
        assertBool (show (diagnostics result)) (all ((/= D.Error) . D.diagnosticSeverity) (diagnostics result))
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
        case Protocol.definitionAt (Compile.compileSources (compilation result)) source index (L.Position 1 19) of
          Nothing -> assertFailure "missing local definition"
          Just location -> location ^. L.range @?= L.Range (L.Position 1 12) (L.Position 1 13),
      testCase "changed dependencies invalidate dependent type information" $ do
        let library = root <> "/Library.ficus"
            source = prefix <> "use Library (value)\ncheck () = if { value -> 1; _ -> 0 }\n"
        valid <- checked [(file, source), (library, prefix <> "value = True\n")]
        diagnostics valid @?= []
        invalid <- checked [(file, source), (library, prefix <> "value = 1\n")]
        assertBool "dependent type error" (any ((== D.Error) . D.diagnosticSeverity) (diagnostics invalid))
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation invalid))
        assertBool "no stale Bool hover" (all ((/= Just "Bool") . Index.symbolType) index),
      testCase "semantic tokens distinguish resolved constructors and parameters" $ do
        let source = prefix <> "type Box a = Box a\ncheck x = Box x\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            tokens = Index.semanticSpans file source index
        assertBool "constructor token" (any (\(location, kind, _) -> S.line (S.start location) == 3 && kind == Index.Constructor) tokens)
        assertBool "parameter token" (any (\(_, kind, _) -> kind == Index.Parameter) tokens)
        case Protocol.semanticTokens file source index of Left message -> assertFailure (T.unpack message); Right _ -> pure (),
      testCase "invalid module names produce editor diagnostics without synthetic Core" $ do
        result <- checked [(root <> "/lowercase.ficus", prefix <> "value = 1\n")]
        map D.diagnosticCode (diagnostics result) @?= ["N0202"]
        Map.size (Compile.compileModules (compilation result)) @?= 0,
      testCase "intrinsic constructors show value types, not kinds" $ do
        let source = prefix <> "value = True\n"
        result <- checked [(file, source)]
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
        fmap hoverText (Protocol.hoverAt source index (L.Position 1 8)) @?= Just "```ficus\nTrue : Bool\n```",
      testCase "trait kinds retain Constraint and primitive types retain semantic roles" $ do
        let source = prefix <> "trait Pick a = { pick : a -> a }\nvalue : Bool\nvalue = True\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
        fmap hoverText (Protocol.hoverAt source index (L.Position 1 7)) @?= Just "```ficus\nPick : Type -> Constraint\n```"
        let boolUses = [Index.symbolClass symbol | symbol <- index, Index.symbolName symbol == "Bool"]
        boolUses @?= [Just Index.TypeName],
      testCase "expression hover includes literal types" $ do
        let source = prefix <> "value = 123\n"
        result <- checked [(file, source)]
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
        fmap hoverText (Protocol.hoverAt source index (L.Position 1 9)) @?= Just "```ficus\n123 : Int\n```",
      testCase "record projection navigates to the nominal field and shows its type" $ do
        let source = prefix <> "type Point = { x : Int; y : Bool }\ncheck (p : Point) = p.x\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
        fmap hoverText (Protocol.hoverAt source index (L.Position 2 22)) @?= Just "```ficus\nx : Int\n```"
        case Protocol.definitionAt (Compile.compileSources (compilation result)) source index (L.Position 2 22) of
          Nothing -> assertFailure "missing field definition"
          Just location -> location ^. L.range @?= L.Range (L.Position 1 15) (L.Position 1 16),
      testCase "closing an import restores disk contents and later disk edits are read" $ withDirectory $ \directory -> do
        let mainFile = directory </> "Main.ficus"
            imported = directory </> "Library.ficus"
            mainSource = prefix <> "use Library (value)\ncheck () = if { value -> 1; _ -> 0 }\n"
            open = Map.singleton mainFile mainSource
            options = LspOptions [directory] [] Nothing
        TIO.writeFile imported (prefix <> "value = True\n")
        first <- analyze options open
        diagnostics first @?= []
        changed <- analyze options (Map.insert imported (prefix <> "value = 1\n") open)
        assertBool "overlay overrides disk" (not (null (diagnostics changed)))
        closed <- analyze options open
        diagnostics closed @?= []
        TIO.writeFile imported (prefix <> "value = 1\n")
        saved <- analyze options open
        assertBool "fresh disk content" (not (null (diagnostics saved)))
    ]

hoverText :: L.Hover -> Text
hoverText hover = case hover ^. L.contents of L.InL content -> content ^. L.value; _ -> ""

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory = bracket acquire removeDirectoryRecursive
  where
    acquire = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "ficus-lsp"
      hClose handle
      removeFile path
      createDirectory path
      pure path

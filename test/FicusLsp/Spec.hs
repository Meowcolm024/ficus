module FicusLsp.Spec (tests) where

import Control.Exception (bracket)
import Control.Lens ((^.))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Ficus.Compile qualified as Compile
import Ficus.Error.Diagnostic qualified as D
import Ficus.ModuleOptions (ModuleOptions (..))
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
checked documents = analyze (ModuleOptions [root] [] Nothing) (Map.fromList documents)

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
      testCase "import soft keywords retain lexical scopes while ordinary as and pub names retain semantic roles" $ do
        let library = root <> "/Library.ficus"
            source = prefix <> "use Library as Lib\nuse Library (as, pub) pub\ncheck as pub = Lib.as (as (Lib.pub (pub 1)))\n"
        result <- checked [(file, source), (library, prefix <> "as x = x\npub x = x\n")]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            tokens = Index.semanticSpans file source index
            at line column = [kind | (location, kind, _) <- tokens, S.line (S.start location) == line, S.column (S.start location) == column]
        at 2 13 @?= []
        at 3 23 @?= []
        at 4 7 @?= [Index.Parameter]
        at 4 10 @?= [Index.Parameter]
        at 4 20 @?= [Index.Function]
        at 4 32 @?= [Index.Function],
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
      testCase "named record patterns distinguish fields, constructors and bound parameters" $ do
        let source = prefix <> "type Point = { x : Int; y : Int }\ncheck (Point with { y = value }) = value\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            tokens = Index.semanticSpans file source index
            at column = [kind | (location, kind, _) <- tokens, S.line (S.start location) == 3, S.column (S.start location) == column]
        at 8 @?= [Index.Constructor]
        at 21 @?= [Index.Property]
        at 25 @?= [Index.Parameter],
      testCase "document outline lists top-level declarations once and omits local bindings" $ do
        let source = prefix <> "type Box a = Box a\nchoose : Bool -> Int\nchoose True = 1\nchoose False = 0\nouter x = { value = x; value }\nother x = { value = x; value }\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            outline = Protocol.documentSymbols file source index
        map (\symbol -> (symbol ^. L.name, symbol ^. L.kind)) outline
          @?= [ ("Box", L.SymbolKind_Class),
                ("choose", L.SymbolKind_Function),
                ("outer", L.SymbolKind_Function),
                ("other", L.SymbolKind_Function)
              ]
        let flat = Protocol.flatDocumentSymbols file outline
        assertBool "local values are absent" (all (\symbol -> symbol ^. L.name /= "value") flat)
        [(symbol ^. L.name, symbol ^. L.containerName) | symbol <- flat, symbol ^. L.kind == L.SymbolKind_EnumMember] @?= [("Box", Just "Box")]
        Protocol.documentSymbols file "" [] @?= [],
      testCase "document outline includes record fields and trait methods" $ do
        let source = prefix <> "type Point = { x : Int }\ntrait Pick a = { pick : a -> a }\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            outline = Protocol.documentSymbols file source index
        map (\symbol -> (symbol ^. L.name, symbol ^. L.kind)) outline
          @?= [("Point", L.SymbolKind_Class), ("Pick", L.SymbolKind_Interface)]
        [(parent ^. L.name, child ^. L.name, child ^. L.kind) | parent <- outline, child <- maybe [] id (parent ^. L.children)]
          @?= [("Point", "x", L.SymbolKind_Field), ("Pick", "pick", L.SymbolKind_Method)],
      testCase "where declarations are omitted and function ranges include their bodies" $ do
        let source = prefix <> "main : Int -> Int\nmain x = helper x where\n    helper y = leaf y where { leaf z = z }\nother x = x\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            outline = Protocol.documentSymbols file source index
        map (\symbol -> symbol ^. L.name) outline @?= ["main", "other"]
        case outline of
          main : _ -> do
            main ^. L.selectionRange @?= L.Range (L.Position 1 0) (L.Position 1 4)
            main ^. L.range @?= L.Range (L.Position 1 0) (L.Position 3 42)
            main ^. L.children @?= Just []
          [] -> assertFailure "missing main outline entry",
      testCase "outline includes imports, aliases, ADT constructors and trait implementations" $ do
        let library = root <> "/Library.ficus"
            source = prefix <> "use Library as Lib\nuse Library (value) pub\nAlias = Int\ntype Box a = Box a\ntrait Pick a = { pick : a -> a }\nimpl Pick Int = { pick x = helper x where { helper y = y } }\ncheck x = Lib.value x\n"
        result <- checked [(file, source), (library, prefix <> "value x = x\n")]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            outline = Protocol.documentSymbols file source index
        map (\symbol -> symbol ^. L.name) outline @?= ["Library as Lib", "Library", "Alias", "Box", "Pick", "impl Pick Int", "check"]
        [(parent ^. L.name, child ^. L.name) | parent <- outline, child <- maybe [] id (parent ^. L.children)]
          @?= [("Box", "Box"), ("Pick", "pick"), ("impl Pick Int", "pick")]
        let flat = Protocol.flatDocumentSymbols file outline
        assertBool "implementation locals are absent" (all (\symbol -> symbol ^. L.name /= "helper") flat)
        [(symbol ^. L.name, symbol ^. L.containerName) | symbol <- flat, symbol ^. L.name == "pick"] @?= [("pick", Just "Pick"), ("pick", Just "impl Pick Int")],
      testCase "a function signature and definition share semantic highlighting and hover" $ do
        let source = prefix <> "identity : Int -> Int\nidentity x = x\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            names = [(S.line (S.start location), kind, declared) | (location, kind, declared) <- Index.semanticSpans file source index, S.column (S.start location) == 1, S.line (S.start location) > 1]
        names @?= [(2, Index.Function, True), (3, Index.Function, True)]
        fmap hoverText (Protocol.hoverAt source index (L.Position 1 1)) @?= Just "```ficus\nidentity : Int -> Int\n```"
        fmap hoverText (Protocol.hoverAt source index (L.Position 2 1)) @?= Just "```ficus\nidentity : Int -> Int\n```",
      testCase "every function clause has the signature's semantic role and canonical definition" $ do
        let source = prefix <> "choose : Bool -> Int\nchoose True = 1\nchoose False = 0\n"
        result <- checked [(file, source)]
        diagnostics result @?= []
        let sources = Compile.compileSources (compilation result)
            index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            names = [(S.line (S.start location), kind, declared) | (location, kind, declared) <- Index.semanticSpans file source index, S.column (S.start location) == 1, S.line (S.start location) > 1]
        names @?= [(2, Index.Function, True), (3, Index.Function, True), (4, Index.Function, True)]
        mapM_
          ( \line -> case Protocol.definitionAt sources source index (L.Position line 1) of
              Nothing -> assertFailure "missing clause definition"
              Just location -> location ^. L.range @?= L.Range (L.Position 1 0) (L.Position 1 6)
          )
          [2, 3],
      testCase "interpolated strings retain lexical highlighting instead of a whole-string variable token" $ do
        let source = "value = \"head args = {x}\"\n"
            location = S.Span file (S.Position 1 9 8) (S.Position 1 25 24)
            -- Generated interpolation references inherit the original string's span.
            symbol = Index.Symbol location "x" Nothing Nothing (Just Index.Parameter) False
            strings = [kind | (span', kind, _) <- Index.semanticSpans file source [symbol], Index.within location span']
        strings @?= []
        Protocol.semanticTokens file source [symbol] @?= Protocol.semanticTokens file source [],
      testCase "two interpolations have separate reference ranges and literal text has no definition" $ do
        let source = "greet : String -> Int -> String\ngreet name count = \"Hello, {name}! Argument count: {count}\"\n"
        result <- analyze (ModuleOptions [root] ["library"] Nothing) (Map.singleton file source)
        diagnostics result @?= []
        let sources = Compile.compileSources (compilation result)
            index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            position text = offsetPosition source (T.length (fst (T.breakOn text source)))
            definitionAt text = Protocol.definitionAt sources source index (position text)
            assertTarget text expected = case definitionAt text of
              Nothing -> assertFailure ("missing reference for " <> T.unpack text)
              Just location -> location ^. L.range @?= expected
        assertTarget "name}!" (L.Range (L.Position 1 6) (L.Position 1 10))
        assertTarget "count}" (L.Range (L.Position 1 11) (L.Position 1 16))
        mapM_ (\text -> definitionAt text @?= Nothing) ["Hello", "{name", "}!", "Argument", "{count", "}\""]
        mapM_
          ( \(text, name, ty) -> case Protocol.hoverAt source index (position text) of
              Nothing -> assertFailure "missing interpolation hover"
              Just hover -> do
                hoverText hover @?= "```ficus\n" <> name <> " : " <> ty <> "\n```"
                hover ^. L.range @?= Just (L.Range (position text) (offsetPosition source (T.length (fst (T.breakOn text source)) + T.length name)))
          )
          [("name}!", "name", "String"), ("count}", "count", "Int")],
      testCase "qualified interpolations with repeated terminal names navigate independently" $ do
        let left = root <> "/Left.ficus"
            right = root <> "/Right.ficus"
            source = "use Left as L\nuse Right as R\ngreet () = \"{L.value} {R.value} {L.value}\"\n"
        result <- analyze (ModuleOptions [root] ["library"] Nothing) (Map.fromList [(file, source), (left, prefix <> "value = 1\n"), (right, prefix <> "value = True\n")])
        diagnostics result @?= []
        let sources = Compile.compileSources (compilation result)
            index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
        mapM_
          ( \(text, target, ty) -> do
              let position = offsetPosition source (T.length (fst (T.breakOn text source)) + 2)
              case Protocol.definitionAt sources source index position of
                Nothing -> assertFailure "missing qualified interpolation reference"
                Just location -> location ^. L.uri @?= L.filePathToUri target
              fmap hoverText (Protocol.hoverAt source index position) @?= Just ("```ficus\nvalue : " <> ty <> "\n```")
          )
          [("L.value} {", left, "Int"), ("R.value}", right, "Bool"), ("L.value}\"", left, "Int")],
      testCase "escaped braces and Unicode text do not shift interpolation reference ranges" $ do
        let source = "greet : String -> String\ngreet name = \"😀\t{{name}} \\{name\\} \\\\{name} {{{name}}} {name}\"\n"
        result <- analyze (ModuleOptions [root] ["library"] Nothing) (Map.singleton file source)
        diagnostics result @?= []
        let index = Map.findWithDefault [] file (Index.buildIndex (compilation result))
            literalOffset = T.length (fst (T.breakOn "\"😀" source))
            embedded = [symbol | symbol <- index, Index.symbolName symbol == "name", S.offset (S.start (Index.symbolSpan symbol)) > literalOffset, Just _ <- [Index.symbolDefinition symbol]]
            positions = [T.length (fst (T.breakOn text source)) + skip | (text, skip) <- [("\\\\{name}", 3), ("{{{name}}}", 3), ("{name}\"", 1)]]
        length embedded @?= 3
        mapM_
          ( \offset -> case Protocol.hoverAt source index (offsetPosition source offset) of
              Nothing -> assertFailure "missing escaped-string interpolation hover"
              Just hover -> hover ^. L.range @?= Just (L.Range (offsetPosition source offset) (offsetPosition source (offset + 4)))
          )
          positions
        mapM_
          ( \text -> do
              let position = offsetPosition source (T.length (fst (T.breakOn text source)) + 2)
              Protocol.definitionAt (Compile.compileSources (compilation result)) source index position @?= Nothing
          )
          ["{{name}}", "\\{name\\}"],
      testCase "only real interpolation defers string highlighting to the lexical grammar" $ do
        let cases =
              [ ("\"{x}\"", []),
                ("\"{Module._value}\"", []),
                ("\"{{{x}}}\"", []),
                ("\"\\\\{x}\"", []),
                ("\"plain\"", [Index.String]),
                ("\"{{x}}\"", [Index.String]),
                ("\"\\{x\\}\"", [Index.String]),
                ("\"\\\\{{x}}\"", [Index.String])
              ]
        mapM_ (\(source, expected) -> [kind | (_, kind, _) <- Index.semanticSpans file source []] @?= expected) cases,
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
            options = ModuleOptions [directory] [] Nothing
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

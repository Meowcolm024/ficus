module FicusBackend.DriverSpec (tests) where

import Control.Exception (bracket)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Ficus.Compile
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Syntax.Name
import Ficus.Util.Source
import FicusBackend.Driver.Repl qualified as Repl
import FicusBackend.Driver.Run
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.Value (StandardHandle (..))
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.HUnit

root :: FilePath
root = "test/fixtures/backend/driver"

quiet :: R.Effects
quiet = R.Effects (\_ _ -> pure ()) (\_ _ -> pure "")

options :: ModuleOptions
options = ModuleOptions [] ["library"] Nothing

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "fixture failed") pure

session :: IO Repl.Session
session = Repl.newSession options >>= requireRight

result :: Repl.Session -> Text -> Text -> Assertion
result current source expected = do
  (_, output) <- Repl.submit quiet current source >>= requireRight
  output @?= Just expected

commandInput :: [Text] -> IO (Maybe Repl.ReplCommand, [Text], [Text])
commandInput lines' = do
  remaining <- newIORef lines'
  prompts <- newIORef []
  let readLine prompt = do
        modifyIORef' prompts (<> [prompt])
        readIORef remaining >>= \case
          [] -> pure Nothing
          line : rest -> do
            modifyIORef' remaining (const rest)
            pure (Just line)
  command <- Repl.readCommand readLine
  rest <- readIORef remaining
  displayed <- readIORef prompts
  pure (command, rest, displayed)

multilineSource :: [Text] -> IO Text
multilineSource body = do
  (command, remaining, _) <- commandInput ([":{"] ++ body ++ [":}"])
  remaining @?= []
  case command of
    Just (Repl.Submit source) -> pure source
    _ -> assertFailure (show command) >> fail "expected multiline submission"

fixture :: Text -> IO CompileResult
fixture name = compileFiles libraryResolveConfig librarySugarRegistry (ModuleOptions [] ["library"] Nothing) ((root </> T.unpack name ++ ".ficus") :| [])

plan :: Text -> IO RunPlan
plan name = do
  compiled <- fixture name
  requireRight (prepareRun (ModuleId (name :| [])) compiled)

tests :: TestTree
tests =
  testGroup
    "backend drivers"
    [ testGroup
        "run"
        [ testCase "Unit entry succeeds" $ do
            prepared <- plan "UnitMain"
            executeRun quiet prepared [] >>= (@?= Right Nothing),
          testCase "Result Ok succeeds" $ do
            prepared <- plan "OkMain"
            executeRun quiet prepared [] >>= (@?= Right Nothing),
          testCase "Result Err returns the application error" $ do
            prepared <- plan "ErrMain"
            executeRun quiet prepared [] >>= (@?= Right (Just "entry failed")),
          testCase "command line arguments exclude the executable and source file" $ do
            output <- newIORef []
            prepared <- plan "ArgsMain"
            executeRun (R.Effects (\handle text -> modifyIORef' output (<> [(handle, text)])) (\_ _ -> pure "")) prepared ["hello", "world"] >>= (@?= Right Nothing)
            readIORef output >>= (@?= [(StandardOutput, "hello\n")]),
          testCase "an imported main is not automatically invoked" $ do
            prepared <- plan "LocalMain"
            executeRun quiet prepared [] >>= (@?= Right Nothing),
          testCase "division by zero returns a structured error" $ do
            prepared <- plan "DivisionMain"
            executeRun quiet prepared [] >>= \case
              Left problem -> assertBool "division failure message" ("integer division by zero" `T.isInfixOf` R.errorMessage problem && "uncaught exception" `T.isSuffixOf` R.errorMessage problem)
              Right value -> assertFailure (show value),
          invalidEntry "BadMain" 3,
          invalidEntry "PolyMain" 3,
          testCase "missing and reexported main are rejected" $
            mapM_
              ( \name -> do
                  compiled <- fixture name
                  case prepareRun (ModuleId (name :| [])) compiled of
                    Right _ -> assertFailure "entry accepted"
                    Left errors -> do
                      map D.diagnosticCode errors @?= ["R0101"]
                      map (line . start . D.diagnosticSpan) errors @?= [1]
              )
              ["NoMain", "ReexportMain"]
        ],
      testGroup
        "repl"
        [ testCase "compile reports incomplete matches in bodies and function clauses" $
            mapM_
              ( \(name, startColumn, endColumn) -> do
                  compiled <- fixture name
                  compileSucceeded compiled @?= True
                  let warnings = filter ((== "T0901") . D.diagnosticCode) (compileDiagnostics compiled)
                  map (\problem -> let site = D.diagnosticSpan problem in (line (start site), column (start site), line (end site), column (end site))) warnings @?= [(1, startColumn, 1, endColumn)]
              )
              [("Coverage", 9, 30), ("CoverageFunction", 1, 16)],
          testCase "accepted REPL definitions retain coverage warnings and source spans" $
            mapM_
              ( \(source, firstColumn) -> do
                  current <- session
                  (next, output) <- Repl.submit quiet current source >>= requireRight
                  output @?= Nothing
                  let warnings = Repl.sessionDiagnostics next
                  map D.diagnosticCode warnings @?= ["T0901"]
                  map D.diagnosticSeverity warnings @?= [D.Warning]
                  map (column . start . D.diagnosticSpan) warnings @?= [firstColumn]
                  mapM_
                    ( \problem -> do
                        let site = D.diagnosticSpan problem
                        case Map.lookup (sourceFile site) (Repl.sessionDiagnosticSources next) of
                          Nothing -> assertFailure "warning source is missing"
                          Just text -> T.take (offset (end site) - offset (start site) + 1) (T.drop (offset (start site)) text) @?= T.drop (firstColumn - 1) source
                    )
                    warnings
                  (later, value) <- Repl.submit quiet next "1 + 2" >>= requireRight
                  value @?= Just "3"
                  Repl.sessionDiagnostics later @?= []
              )
              [("foo x = with x { Just x -> x }", 9), ("foo (Just x) = x", 1)],
          testCase "REPL loads retain coverage warnings" $ do
            current <- session
            next <- Repl.loadSession current (root </> "Coverage.ficus") >>= requireRight
            let warnings = filter ((== "T0901") . D.diagnosticCode) (Repl.sessionDiagnostics next)
            map (\problem -> let site = D.diagnosticSpan problem in (line (start site), column (start site), line (end site), column (end site))) warnings @?= [(1, 9, 1, 30)]
            (later, output) <- Repl.submit quiet next "foo (Just 42)" >>= requireRight
            output @?= Just "42"
            Repl.sessionDiagnostics later @?= [],
          testCase "command aliases and arguments" $ do
            map Repl.parseCommand [":q", ":quit"] @?= replicate 2 Repl.Quit
            map Repl.parseCommand [":h", ":help"] @?= replicate 2 Repl.Help
            Repl.parseCommand ":h extra" @?= Repl.InvalidCommand ":help takes no arguments"
            assertBool "help lists commands" (all (`T.isInfixOf` Repl.helpText) [":load", ":type", ":kind", ":quit", ":help"])
            map Repl.parseCommand [":l Foo.ficus", ":load Foo.ficus"] @?= replicate 2 (Repl.Load "Foo.ficus")
            map Repl.parseCommand [":t id", ":type id"] @?= replicate 2 (Repl.TypeOf "id")
            map Repl.parseCommand [":k Functor", ":kind Functor"] @?= replicate 2 (Repl.KindOf "Functor")
            Repl.parseCommand ":k" @?= Repl.InvalidCommand ":kind requires a type-level expression"
            Repl.parseCommand ":load \"some folder/Foo.ficus\"" @?= Repl.Load "some folder/Foo.ficus",
          testCase "help documents multiline delimiters" $
            assertBool "help lists multiline delimiters" (all (`T.isInfixOf` Repl.helpText) [":{", ":}"]),
          testCase "multiline input preserves source and consumes only its block" $ do
            let body = ["  value =", "    \" :} \"", "", ":q", ":{"]
            (command, remaining, prompts) <- commandInput (["  :{  "] ++ body ++ ["  :}  ", "2 + 2"])
            command @?= Just (Repl.Submit (T.unlines body))
            remaining @?= ["2 + 2"]
            prompts @?= "ficus> " : replicate (length body + 1) "ficus| ",
          testCase "multiline input handles empty blocks EOF and stray closing delimiters" $ do
            (empty, _, _) <- commandInput [":{", ":}"]
            empty @?= Just (Repl.Submit "")
            (unfinished, remaining, _) <- commandInput [":{", "value = 1"]
            remaining @?= []
            unfinished @?= Nothing
            (stray, _, _) <- commandInput [":}"]
            assertBool "stray closing delimiter rejected" (case stray of Just (Repl.InvalidCommand _) -> True; _ -> False)
            (eof, _, _) <- commandInput []
            eof @?= Nothing
            (ordinary, rest, prompts) <- commandInput [":t id", "1 + 1"]
            ordinary @?= Just (Repl.TypeOf "id")
            rest @?= ["1 + 1"]
            prompts @?= ["ficus> "],
          testCase "multiline declarations define types traits and orphan implementations" $ do
            current <- session
            source <- multilineSource ["type Token = Token", "trait Label a =", "  label : a -> String", "impl Label Token =", "  label _ = \"token\""]
            (defined, _) <- Repl.submit quiet current source >>= requireRight
            result defined "label Token" "\"token\""
            replacement <- multilineSource ["impl Show Int =", "  show _ = \"multiline\""]
            (replaced, _) <- Repl.submit quiet defined replacement >>= requireRight
            result replaced "show (42 : Int)" "\"multiline\"",
          testCase "multiline expressions preserve indentation and evaluate effects once" $ do
            current <- session
            trace <- newIORef []
            let effects = R.Effects (\_ text -> modifyIORef' trace (<> [text])) (\_ _ -> pure "")
            source <- multilineSource ["{", "  println \"once\";", "", "  40 + 2", "}"]
            readIORef trace >>= (@?= [])
            (_, output) <- Repl.submit effects current source >>= requireRight
            output @?= Just "42"
            readIORef trace >>= (@?= ["once\n"]),
          testCase "kind inspection displays only kinds" $ do
            current <- session
            Repl.inspectKind current "Int" >>= (@?= Right "Int : Type")
            Repl.inspectKind current "Maybe" >>= (@?= Right "Maybe : Type -> Type")
            Repl.inspectKind current "Show" >>= (@?= Right "Show : Type -> Constraint")
            Repl.inspectKind current "Ord" >>= (@?= Right "Ord : Type -> Constraint")
            (next, _) <- Repl.submit quiet current "use Class.Show as S" >>= requireRight
            Repl.inspectKind next "S.Show" >>= (@?= Right "S.Show : Type -> Constraint")
            Repl.inspectKind next "Functor" >>= (@?= Right "Functor : (Type -> Type) -> Constraint"),
          testCase "kind inspection infers type-level expressions" $ do
            current <- session
            Repl.inspectKind current "Maybe Int" >>= (@?= Right "Maybe Int : Type")
            Repl.inspectKind current "Int -> String" >>= (@?= Right "Int -> String : Type")
            Repl.inspectKind current "[Int]" >>= (@?= Right "[Int] : Type")
            Repl.inspectKind current "Functor Maybe" >>= (@?= Right "Functor Maybe : Constraint")
            Repl.inspectKind current "Show Int" >>= (@?= Right "Show Int : Constraint"),
          testCase "kind and term inspection use separate namespaces" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "type Box a = Box a" >>= requireRight
            Repl.inspectKind first "Box" >>= (@?= Right "Box : Type -> Type")
            (second, _) <- Repl.submit quiet first "type Box = Box Int" >>= requireRight
            Repl.inspectKind second "Box" >>= (@?= Right "Box : Type")
            (third, _) <- Repl.submit quiet second "Alias = Box" >>= requireRight
            Repl.inspectKind third "Alias" >>= (@?= Right "Alias : Type")
            Repl.inspectType third "Box" >>= (@?= Right "Box : Int -> Box")
            constructor <- Repl.inspectType third "Just" >>= requireRight
            assertBool "constructors still show schemes" ("a -> Maybe a" `T.isInfixOf` constructor),
          testCase "expressions execute without a main" $ session >>= \current -> result current "1 + 2" "3",
          testCase "type inspection infers expressions without evaluating them" $ do
            current <- session
            Repl.inspectType current "1" >>= (@?= Right "1 : Int")
            Repl.inspectType current "id 1" >>= (@?= Right "id 1 : Int")
            Repl.inspectType current "1 / 0" >>= (@?= Right "1 / 0 : Int")
            Repl.inspectType current "(x -> x)" >>= (@?= Right "(x -> x) : a -> a")
            Repl.inspectType current "(x -> x + x)" >>= (@?= Right "(x -> x + x) : Add a => a -> a")
            Repl.inspectType current "println \"type query\"" >>= (@?= Right "println \"type query\" : Unit")
            result current "2 + 3" "5",
          testCase "bindings accept trailing type annotations" $ do
            current <- session
            (next, _) <- Repl.submit quiet current "x = 2 : Int" >>= requireRight
            Repl.inspectType next "x" >>= (@?= Right "x : Int")
            result next "x" "2",
          testCase "failed hole submissions retain the exact source excerpt" $ do
            current <- session
            (sources, outcome) <- Repl.submitWithSources quiet current "x -> x + _"
            case outcome of
              Right _ -> assertFailure "expression hole was accepted"
              Left errors -> case filter ((== "T0101") . D.diagnosticCode) errors of
                [problem] -> do
                  let origin = D.diagnosticSpan problem
                  case Map.lookup (sourceFile origin) sources of
                    Nothing -> assertFailure "missing failed submission source"
                    Just source -> case drop (line (start origin) - 1) (T.lines source) of
                      text : _ -> do
                        assertBool "expression appears in the diagnostic source" ("x -> x + _" `T.isInfixOf` text)
                        T.take 1 (T.drop (column (start origin) - 1) text) @?= "_"
                      [] -> assertFailure "hole span is outside its source"
                _ -> assertFailure "missing hole diagnostic"
            result current "6 * 7" "42",
          testCase "division by zero leaves the session usable" $ do
            current <- session
            Repl.submit quiet current "1 / 0" >>= \case
              Left errors -> do
                map D.diagnosticCode errors @?= ["R0001"]
                map (sourceFile . D.diagnosticSpan) errors @?= ["<runtime>"]
                assertBool "builtin location is embedded in the message" (all (T.isInfixOf "Int.ficus:11:1: integer division by zero: uncaught exception" . D.diagnosticMessage) errors)
              Right _ -> assertFailure "division succeeded"
            result current "6 * 7" "42",
          testCase "declarations retain inferred types and execute" $ do
            current <- session
            (next, _) <- Repl.submit quiet current "double x = x + x" >>= requireRight
            result next "double 21" "42"
            Repl.inspectType next "double" >>= (@?= Right "double : Add a => a -> a"),
          testCase "type inspection retains polymorphism and constraints" $ do
            current <- session
            Repl.inspectType current "id" >>= (@?= Right "id : {a} -> a -> a")
            Repl.inspectType current "show" >>= (@?= Right "show : Show a => a -> String"),
          testCase "loading brings file definitions into scope" $ do
            current <- session
            loaded <- Repl.loadSession current (root </> "Values.ficus") >>= requireRight
            result loaded "value + 1" "42"
            Repl.inspectType loaded "value" >>= (@?= Right "value : Int"),
          testCase "interactive imports work" $ do
            current <- session
            (next, _) <- Repl.submit quiet current "use Data.Vec (..)" >>= requireRight
            result next "vecLength (listToVec [1, 2, 3])" "3",
          testCase "interactive orphan implementations replace imported and earlier instances" $ do
            current <- session
            (saved, _) <- Repl.submit quiet current "old () = show (1 : Int)" >>= requireRight
            (first, _) <- Repl.submit quiet saved "impl Show Int = { show _ = \"first\" }" >>= requireRight
            result first "show (1 : Int)" "\"first\""
            (second, _) <- Repl.submit quiet first "impl Show Int = { show _ = \"second\" }" >>= requireRight
            (later, _) <- Repl.submit quiet second "fresh () = show (1 : Int)" >>= requireRight
            result later "fresh ()" "\"second\""
            result later "old ()" "\"1\""
            result later "show True" "\"True\""
            (imported, _) <- Repl.submit quiet later "use Data.Vec (..)" >>= requireRight
            result imported "show (1 : Int)" "\"second\"",
          testCase "interactive orphan implementations may introduce a new instance" $ withDirectory $ \directory -> do
            let file = directory </> "Foreign.ficus"
            TIO.writeFile file "type Foreign = Foreign\n"
            current <- session
            loaded <- Repl.loadSession current file >>= requireRight
            (next, _) <- Repl.submit quiet loaded "impl Show Foreign = { show _ = \"foreign\" }" >>= requireRight
            result next "show Foreign" "\"foreign\"",
          testCase "new types traits and implementations work across REPL submissions" $ do
            current <- session
            (typed, _) <- Repl.submit quiet current "type Box a = Box a" >>= requireRight
            (trait, _) <- Repl.submit quiet typed "trait Describe a = { describe : a -> String }" >>= requireRight
            (implemented, _) <- Repl.submit quiet trait "impl Show a => Describe (Box a) = { describe (Box value) = show value }" >>= requireRight
            (later, _) <- Repl.submit quiet implemented "describeBox value = describe (Box value)" >>= requireRight
            result later "describeBox (42 : Int)" "\"42\""
            Repl.inspectKind later "Box" >>= (@?= Right "Box : Type -> Type")
            Repl.inspectKind later "Describe" >>= (@?= Right "Describe : Type -> Constraint")
            (saved, _) <- Repl.submit quiet later "oldBox () = describe (Box (42 : Int))" >>= requireRight
            (replaced, _) <- Repl.submit quiet saved "impl Describe (Box a) = { describe _ = \"box\" }" >>= requireRight
            result replaced "describe (Box True)" "\"box\""
            result replaced "describeBox (42 : Int)" "\"box\""
            result replaced "oldBox ()" "\"42\"",
          testCase "new types traits and implementations work within one REPL submission" $ do
            current <- session
            (next, _) <- Repl.submit quiet current (T.unlines ["type Token = Token", "trait Label a = { label : a -> String }", "impl Label Token = { label _ = \"token\" }"]) >>= requireRight
            result next "label Token" "\"token\"",
          testCase "failed interactive implementations preserve the previous instance" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "impl Show Int = { show _ = \"first\" }" >>= requireRight
            Repl.submit quiet first "impl Show Int = {}" >>= \case
              Left errors -> do
                map D.diagnosticCode errors @?= ["T0403"]
                map (column . start . D.diagnosticSpan) errors @?= [1]
              Right _ -> assertFailure "incomplete implementation accepted"
            result first "show (1 : Int)" "\"first\"",
          testCase "overlapping implementations in one REPL submission remain errors" $ do
            current <- session
            let declaration = "impl Show Int = { show _ = \"duplicate\" }"
            Repl.submit quiet current (T.unlines [declaration, declaration]) >>= \case
              Left errors -> do
                map D.diagnosticCode errors @?= ["T0406"]
                map (\problem -> let site = D.diagnosticSpan problem in (sourceFile site, column (start site), column (end site))) errors @?= [("<repl:1>", 1, T.length declaration)]
              Right _ -> assertFailure "overlapping implementations accepted in one submission"
            result current "show (1 : Int)" "\"1\"",
          testCase "loaded files retain orphan implementation checks" $ withDirectory $ \directory -> do
            let file = directory </> "Orphan.ficus"
            TIO.writeFile file "impl Show Int = { show _ = \"orphan\" }\n"
            current <- session
            Repl.loadSession current file >>= \case
              Left errors -> do
                let orphans = filter ((== "T0408") . D.diagnosticCode) errors
                map (\problem -> let site = D.diagnosticSpan problem in (sourceFile site, line (start site), column (start site), column (end site))) orphans @?= [(file, 1, 6, 13)]
              Right _ -> assertFailure "orphan implementation accepted in a file"
            result current "show (1 : Int)" "\"1\"",
          testCase "import shorthand is not accepted" $ do
            current <- session
            Repl.submit quiet current "import Data.Vec" >>= \case
              Left errors -> do
                map D.diagnosticCode errors @?= ["N0001"]
                map (sourceFile . D.diagnosticSpan) errors @?= ["<repl:1>"]
              Right _ -> assertFailure "import shorthand accepted"
            result current "1 + 1" "2",
          testCase "failed imports preserve the previous environment" $ do
            current <- session
            Repl.submit quiet current "use MissingModule (..)" >>= \case
              Left _ -> pure ()
              Right _ -> assertFailure "missing import accepted"
            result current "1 + 1" "2",
          testCase "expansive bindings evaluate once and permit rebinding" $ do
            current <- session
            trace <- newIORef []
            let effects = R.Effects (\_ text -> modifyIORef' trace (<> [text])) (\_ _ -> pure "")
            (first, _) <- Repl.submit effects current "answer = { println \"once\"; 40 + 2 }" >>= requireRight
            result first "answer" "42"
            (second, _) <- Repl.submit effects first "answer = answer + 1" >>= requireRight
            result second "answer" "43"
            readIORef trace >>= (@?= ["once\n"]),
          testCase "expansive bindings retain value restriction and recursive safety" $ do
            current <- session
            Repl.submit quiet current "weak = id []" >>= \case
              Left errors -> assertBool (show errors) ("T0102" `elem` map D.diagnosticCode errors)
              Right _ -> assertFailure "an unresolved expansive binding was generalized"
            Repl.submit quiet current "cycle = cycle + 1" >>= \case
              Left errors -> assertBool (show errors) ("T0202" `elem` map D.diagnosticCode errors)
              Right _ -> assertFailure "unsafe recursive initializer accepted"
            result current "1 + 1" "2",
          testCase "old closures retain their bindings after a type-changing rebind" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "value = 7" >>= requireRight
            (second, _) <- Repl.submit quiet first "old () = value" >>= requireRight
            (third, _) <- Repl.submit quiet second "value = True" >>= requireRight
            result third "value" "True"
            result third "old ()" "7"
            Repl.inspectType third "value" >>= (@?= Right "value : Bool"),
          testCase "type rebinding permits its own constructor and preserves old values" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "type Box = Box Int Int" >>= requireRight
            (second, _) <- Repl.submit quiet first "old = Box 7 0" >>= requireRight
            (third, _) <- Repl.submit quiet second "unbox (Box x _) = x" >>= requireRight
            (fourth, _) <- Repl.submit quiet third "type Box = Box String String" >>= requireRight
            result fourth "unbox old" "7"
            result fourth "with Box \"new\" \"extra\" { Box text _ -> text }" "\"new\""
            Repl.submit quiet fourth "unbox (Box \"new\" \"extra\")" >>= \case
              Left _ -> pure ()
              Right _ -> assertFailure "nominally distinct Box types unified",
          testCase "removed Prelude constructors stay hidden after type rebinding" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "type Maybe a = Different a" >>= requireRight
            (second, _) <- Repl.submit quiet first "value = Different 7" >>= requireRight
            Repl.submit quiet second "Just 3" >>= \case
              Left errors -> map D.diagnosticCode errors @?= ["N0001"]
              Right _ -> assertFailure "constructor from the old Maybe remained visible"
            result second "with value { Different x -> x }" "7",
          testCase "constructor rebinding cannot take a name owned by another type" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "type First = Shared Int" >>= requireRight
            Repl.submit quiet first "type Second = Shared String" >>= \case
              Left errors -> map D.diagnosticCode errors @?= ["R0104"]
              Right _ -> assertFailure "unrelated constructor overwritten"
            result first "with Shared 3 { Shared x -> x }" "3",
          testCase "failed expansive rebinding preserves the old value" $ do
            current <- session
            (first, _) <- Repl.submit quiet current "value = 7" >>= requireRight
            Repl.submit quiet first "value = 1 / 0" >>= \case
              Left errors -> map D.diagnosticCode errors @?= ["R0001"]
              Right _ -> assertFailure "division succeeded"
            result first "value" "7",
          testCase "reload replaces values and failed reload retains the snapshot" $ withDirectory $ \directory -> do
            let file = directory </> "Reload.ficus"
            TIO.writeFile file "value = 1\n"
            current <- session
            first <- Repl.loadSession current file >>= requireRight
            TIO.writeFile file "value = 2\n"
            result first "value" "1"
            second <- Repl.loadSession first file >>= requireRight
            result second "value" "2"
            TIO.writeFile file "value = missing\n"
            Repl.loadSession second file >>= \case
              Left _ -> pure ()
              Right _ -> assertFailure "invalid reload accepted"
            result second "value" "2"
        ]
    ]
  where
    invalidEntry name expectedLine = testCase ("reject invalid main in " ++ T.unpack name) $ do
      compiled <- fixture name
      assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
      case prepareRun (ModuleId (name :| [])) compiled of
        Right _ -> assertFailure "invalid main accepted"
        Left errors -> do
          map D.diagnosticCode errors @?= ["R0101"]
          map (line . start . D.diagnosticSpan) errors @?= [expectedLine]

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory = bracket allocate removeDirectoryRecursive
  where
    allocate = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "ficus-repl"
      hClose handle
      removeFile path
      createDirectory path
      pure path

-- | Source entry validation and runtime invocation, outside the Runtime stage.
module FicusBackend.Driver.Run (RunPlan, prepareRun, executeRun, lowerCompilation) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate (validatedModule)
import Ficus.Syntax.Name
import Ficus.Type hiding (TypeKind)
import Ficus.Type qualified as T
import Ficus.Util.Source
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as A

-- Tags are selected during preparation, never by source-name lookup at runtime.
data ReturnForm = UnitReturn | ResultReturn A.ConstructorIndex A.ConstructorIndex

data RunPlan = RunPlan R.Executable R.Entry ReturnForm Span

lowerCompilation :: CompileResult -> Either [D.Diagnostic] LoweredProgram
lowerCompilation result
  | not (compileSucceeded result) = Left (compileDiagnostics result)
  | otherwise = case lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder result, Just checked <- [Map.lookup owner (compileModules result)]] of
      Left errors -> Left (map D.toDiagnostic errors)
      Right program -> Right program

prepareRun :: ModuleId -> CompileResult -> Either [D.Diagnostic] RunPlan
prepareRun owner result
  | not (compileSucceeded result) = Left (compileDiagnostics result)
  | otherwise = do
      checked <- maybe (Left [entryError fallback "selected entry module did not compile"]) Right (Map.lookup owner (compileModules result))
      let core = validatedModule (checkedCore checked)
          ident = GlobalId owner ValueNS "main"
          bindings = [binding | group <- C.coreBindings core, binding <- C.groupBindings group, C.bindingReference (C.nodeValue binding) == GlobalRef ident]
      binding <- case bindings of
        [value] -> Right value
        _ -> Left [entryError (C.coreSpan core) "selected module must define its own main"]
      let scheme = C.bindingScheme (C.nodeValue binding)
          origin = C.nodeSpan binding
          unit = primitive UnitType
          resultType = Application (Application (Constructor (GlobalId (ModuleId ("Data" :| ["Result"])) TypeNS "Result") (T.KindArrow T.TypeKind (T.KindArrow T.TypeKind T.TypeKind))) (primitive StringType)) unit
      unlessEntry origin (null (quantifiers scheme) && null (schemePredicates scheme))
      output <- case functionParts (schemeType scheme) of
        Just (input, output) | input == list (primitive StringType) && (output == unit || output == resultType) -> Right output
        _ -> Left [entryError origin "main must have type [String] -> Unit or [String] -> Result String Unit"]
      lowered <- lowerCompilation result
      address <- maybe (Left [entryError origin "main has no runtime address"]) Right (Map.lookup ident (loweredGlobals lowered))
      entry <- either (Left . pure . D.toDiagnostic) Right (R.selectEntry (loweredProgram lowered) address)
      form <- if output == unit then Right UnitReturn else ResultReturn <$> tag lowered origin "Err" <*> tag lowered origin "Ok"
      pure (RunPlan (R.compileProgram (loweredProgram lowered)) entry form origin)
  where
    fallback = Span "<entry>" (Position 1 1 0) (Position 1 1 0)
    unlessEntry origin valid = if valid then Right () else Left [entryError origin "main must be monomorphic and have no trait constraints"]
    tag lowered origin name = maybe (Left [entryError origin "entry Result constructors are not linked"]) Right (Map.lookup (C.DataConstructor (GlobalId (ModuleId ("Data" :| ["Result"])) ConstructorNS name)) (loweredConstructors lowered))

entryError :: Span -> Text -> D.Diagnostic
entryError origin message = D.Diagnostic "R0101" D.Error origin message Nothing []

-- | Err is an application-level failure, separate from evaluator failure.
executeRun :: R.Effects -> RunPlan -> [Text] -> IO (Either R.RuntimeError (Maybe Text))
executeRun effects (RunPlan executable entry form origin) arguments = do
  let values = foldr (\argument rest -> R.Aggregate A.consConstructor (V.fromList [R.LiteralValue (A.String argument), rest])) (R.Aggregate A.nilConstructor V.empty) arguments
  outcome <- R.runProgram effects executable entry [values]
  pure (outcome >>= finish)
  where
    finish value = case (form, value) of
      (UnitReturn, R.LiteralValue A.Unit) -> Right Nothing
      (ResultReturn err _, R.Aggregate actual fields) | actual == err -> case V.toList fields of
        [R.LiteralValue (A.String message)] -> Right (Just message)
        _ -> invalid
      (ResultReturn _ ok, R.Aggregate actual fields) | actual == ok -> case V.toList fields of
        [R.LiteralValue A.Unit] -> Right Nothing
        _ -> invalid
      _ -> invalid
    invalid = Left (R.RuntimeError (Text.pack (sourceFile origin) <> ": entry returned an invalid runtime representation"))

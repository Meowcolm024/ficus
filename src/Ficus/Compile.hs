-- | Discover, resolve, infer and elaborate modules in dependency order.
-- Configuration and source caching belong here, outside the individual passes.
module Ficus.Compile (CompileResult (..), compileFiles, compileProvided, compileInteractiveProvided, compileSucceeded, compileDiagnostics) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (modify', runStateT)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Desugar.Registry (SugarRegistry)
import Ficus.Elaborate qualified as Elaborate
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Resolve qualified as R
import Ficus.Error.Type qualified as E
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve
import Ficus.Resolve.Desugar (ResolveConfig)
import Ficus.Resolve.Discovery
import Ficus.Resolve.Header (edgeTarget, headerEdges)
import Ficus.Resolve.Provider qualified as Provider
import Ficus.Syntax.Name (ModuleId, NameSummary)
import Ficus.Util.Source
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath (normalise, takeDirectory, takeExtension)

data CompileResult = CompileResult
  { compileFrontend :: FrontendResult,
    compileSources :: Map FilePath Text,
    compileOrder :: [ModuleId],
    compileModules :: Map ModuleId Elaborate.CheckedModule,
    compileTypeDiagnostics :: [E.Diagnostic]
  }
  deriving (Eq, Show)

compileSucceeded :: CompileResult -> Bool
compileSucceeded = all ((/= D.Error) . D.diagnosticSeverity) . compileDiagnostics

compileDiagnostics :: CompileResult -> [D.Diagnostic]
compileDiagnostics result = map D.toDiagnostic (frontendDiagnostics (compileFrontend result)) ++ map D.toDiagnostic (compileTypeDiagnostics result)

compileFiles :: ResolveConfig -> SugarRegistry -> ModuleOptions -> NonEmpty FilePath -> IO CompileResult
compileFiles resolver sugar options inputs = do
  files <- traverse absolute inputs
  roots <- nub <$> mapM absolute (if null (sourceRoots options) then map takeDirectory (NE.toList files) else sourceRoots options)
  libraries <- mapM absolute (libraryRoots options)
  prelude <- traverse absolute (preludeFile options)
  identities <- mapM (entryIdentity roots) (NE.toList files)
  let entries = [(owner, Span file (Position 1 1 0) (Position 1 1 0)) | (file, Right owner) <- zip (NE.toList files) identities]
      entryErrors = [ResolutionDiagnostic d | Left d <- identities]
      config = Provider.ProviderConfig (nub (roots ++ libraries)) (maybe Provider.PreludeFromRoots Provider.PreludeFile prelude)
  result <- compileProvided resolver sugar (Provider.fileProvider config) entries
  let frontend = compileFrontend result
  pure (result {compileFrontend = frontend {frontendDiagnostics = entryErrors ++ frontendDiagnostics frontend}})
  where
    absolute path = normalise <$> makeAbsolute path

-- | Compile through an injected source provider, including unsaved interactive
-- modules, while retaining dependency order for linking and initialization.
compileProvided :: ResolveConfig -> SugarRegistry -> Provider.ModuleProvider IO -> [(ModuleId, Span)] -> IO CompileResult
compileProvided = compileInteractiveProvided Map.empty

-- | Only modules explicitly present in scopes receive interactive initialization
-- and name shadowing. Ordinary source files retain the normal language rules.
compileInteractiveProvided :: Map ModuleId NameSummary -> ResolveConfig -> SugarRegistry -> Provider.ModuleProvider IO -> [(ModuleId, Span)] -> IO CompileResult
compileInteractiveProvided scopes resolver sugar sourceProvider entries = do
  let provider owner = do
        result <- liftIO (sourceProvider owner)
        case result of
          Right source -> modify' (Map.insert (Provider.sourcePath source) (Provider.sourceText source))
          Left _ -> pure ()
        pure result
  (graph, sources) <- runStateT (discoverModulesAt provider entries) Map.empty
  let frontend = resolveGraphWithNames scopes resolver sugar graph
      (checked, diagnostics) = foldl (checkModule scopes graph frontend) (Map.empty, []) (dependencyOrder graph)
  pure (CompileResult frontend sources (dependencyOrder graph) checked diagnostics)

checkModule :: Map ModuleId NameSummary -> ModuleGraph -> FrontendResult -> (Map ModuleId Elaborate.CheckedModule, [E.Diagnostic]) -> ModuleId -> (Map ModuleId Elaborate.CheckedModule, [E.Diagnostic])
checkModule scopes graph frontend previous@(checked, diagnostics) owner = case (Map.lookup owner (frontendModules frontend), Map.lookup owner (graphModules graph)) of
  (Just source, Just discovered) ->
    let dependencies = map edgeTarget (headerEdges (discoveredHeader discovered))
     in case traverse (`Map.lookup` checked) dependencies of
          Nothing -> previous
          Just imports -> case elaborate (map Elaborate.checkedInterface imports) source of
            Elaborate.Incomplete _ errors -> (checked, diagnostics ++ errors)
            Elaborate.Complete result warnings -> (Map.insert owner result checked, diagnostics ++ warnings)
  _ -> previous
  where
    elaborate = if Map.member owner scopes then Elaborate.elaborateInteractiveModule else Elaborate.elaborateModule

entryIdentity :: [FilePath] -> FilePath -> IO (Either R.Diagnostic ModuleId)
entryIdentity roots file = do
  exists <- doesFileExist file
  pure $
    if exists
      then identity
      else Left (R.diagnostic R.ModuleNotFound anchor ("input file not found: " <> T.pack file))
  where
    anchor = Span file (Position 1 1 0) (Position 1 1 0)
    identity
      | takeExtension file /= ".ficus" = invalid "input files must have the .ficus extension"
      | otherwise = case nub [owner | root <- roots, Right owner <- [Provider.moduleIdentity root file]] of
          [owner] -> Right owner
          [] -> invalid "input must have an uppercase module path relative to a project source root"
          _ -> invalid "input has multiple module identities; choose an unambiguous --source-root"
    invalid message = Left (R.diagnostic R.InvalidModuleIdentity anchor message)

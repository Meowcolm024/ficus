-- | Early-development compile driver: discover, parse, and resolve only.
-- Configuration and source caching belong here, outside the individual passes.
module Ficus.Compile (CompileOptions (..), CompileResult (..), compileFiles, compileSucceeded) where

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
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Resolve qualified as R
import Ficus.Resolve
import Ficus.Resolve.Desugar (ResolveConfig)
import Ficus.Resolve.Discovery
import Ficus.Resolve.Provider qualified as Provider
import Ficus.Syntax.Name (ModuleId)
import Ficus.Util.Source
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath (normalise, takeDirectory, takeExtension)

data CompileOptions = CompileOptions
  { inputFiles :: NonEmpty FilePath,
    projectRoots :: [FilePath],
    libraryRoots :: [FilePath],
    preludeFile :: Maybe FilePath
  }
  deriving (Eq, Show)

data CompileResult = CompileResult
  { compileFrontend :: FrontendResult,
    compileSources :: Map FilePath Text
  }
  deriving (Eq, Show)

compileSucceeded :: CompileResult -> Bool
compileSucceeded = all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) . frontendDiagnostics . compileFrontend

compileFiles :: ResolveConfig -> SugarRegistry -> CompileOptions -> IO CompileResult
compileFiles resolver sugar options = do
  files <- traverse absolute (inputFiles options)
  roots <- nub <$> mapM absolute (if null (projectRoots options) then map takeDirectory (NE.toList files) else projectRoots options)
  libraries <- mapM absolute (libraryRoots options)
  prelude <- traverse absolute (preludeFile options)
  identities <- mapM (entryIdentity roots) (NE.toList files)
  let entries = [(owner, Span file (Position 1 1 0) (Position 1 1 0)) | (file, Right owner) <- zip (NE.toList files) identities]
      entryErrors = [ResolutionDiagnostic d | Left d <- identities]
      config = Provider.ProviderConfig (nub (roots ++ libraries)) (maybe Provider.PreludeFromRoots Provider.PreludeFile prelude)
      provider owner = do
        result <- liftIO (Provider.fileProvider config owner)
        case result of
          Right source -> modify' (Map.insert (Provider.sourcePath source) (Provider.sourceText source))
          Left _ -> pure ()
        pure result
  (graph, sources) <- runStateT (discoverModulesAt provider entries) Map.empty
  let frontend = resolveGraph resolver sugar graph
  pure (CompileResult (frontend {frontendDiagnostics = entryErrors ++ frontendDiagnostics frontend}) sources)
  where
    absolute path = normalise <$> makeAbsolute path

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

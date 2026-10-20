-- | Editor source overlays and analysis live outside the compiler. Compiling
-- an overlay uses the same ordinary module rules as compilation from disk.
module FicusLsp.Workspace where

import Control.Monad (filterM)
import Data.List (nub)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Ficus.Compile qualified as C
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve.Provider qualified as P
import Ficus.Syntax.Name
import Ficus.Util.Source
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath (normalise, takeDirectory, takeExtension, (<.>), (</>))
import System.IO.Error (tryIOError)

defaultOptions :: ModuleOptions
defaultOptions = ModuleOptions [] [] Nothing

-- All paths in a workspace snapshot are absolute and normalized.
type Documents = Map FilePath Text

data Analysis = Analysis {compilation :: C.CompileResult, diagnostics :: [D.Diagnostic]} deriving (Eq, Show)

normalizeOptions :: ModuleOptions -> IO ModuleOptions
normalizeOptions options = ModuleOptions <$> mapM absolute (sourceRoots options) <*> mapM absolute (libraryRoots options) <*> traverse absolute (preludeFile options)
  where
    absolute path = normalise <$> makeAbsolute path

analyze :: ModuleOptions -> Documents -> IO Analysis
analyze options documents = do
  let roots = nub (if null (sourceRoots options) then map takeDirectory (Map.keys documents) else sourceRoots options)
      identities = [(file, identity roots file) | file <- Map.keys documents]
      entries = [(owner, anchor file) | (file, Right owner) <- identities]
      problems = [D.Diagnostic "N0202" D.Error (anchor file) message Nothing [] | (file, Left message) <- identities]
      providerOptions = P.ProviderConfig (nub (roots ++ libraryRoots options)) (maybe P.PreludeFromRoots P.PreludeFile (preludeFile options))
  result <- C.compileProvided libraryResolveConfig librarySugarRegistry (overlayProvider providerOptions documents) entries
  -- Entry-name errors are editor diagnostics, not invented compiler nodes.
  pure (Analysis (result {C.compileSources = documents `Map.union` C.compileSources result}) (problems ++ C.compileDiagnostics result))
  where
    identity roots file
      | takeExtension file /= ".ficus" = Left "input files must have the .ficus extension"
      | otherwise = case nub [owner | root <- roots, Right owner <- [P.moduleIdentity root file]] of
          [owner] -> Right owner
          [] -> Left "input must have an uppercase module path relative to a source root"
          _ -> Left "input has multiple module identities; configure unambiguous source roots"
    anchor file = Span file (Position 1 1 0) (Position 1 1 0)

-- Match fileProvider's ambiguity policy even when a candidate exists only in
-- the editor. Never let the overlay silently choose one of two module files.
overlayProvider :: P.ProviderConfig -> Documents -> P.ModuleProvider IO
overlayProvider options documents owner = do
  let ModuleId parts = owner
      relative = foldl (</>) "" (map T.unpack (NE.toList parts)) <.> "ficus"
      candidates =
        nub
          ( map
              normalise
              ( case (owner, P.preludeSource options) of
                  (ModuleId ("Prelude" NE.:| []), P.PreludeFile file) -> [file]
                  _ -> [root </> relative | root <- P.sourceRoots options]
              )
          )
  existing <- filterM (\file -> if Map.member file documents then pure True else doesFileExist file) candidates
  case existing of
    [] -> pure (Left ("module not found; searched " <> T.pack (show candidates)))
    [file] -> case Map.lookup file documents of
      Just text -> pure (Right (P.Source file text))
      Nothing -> do
        result <- tryIOError (T.readFile file)
        pure (either (Left . T.pack . show) (Right . P.Source file) result)
    _ -> pure (Left ("multiple module files; configure unambiguous roots: " <> T.pack (show existing)))

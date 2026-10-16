-- | File lookup only: no parsing, discovery, or desugaring dependencies.
module Ficus.Resolve.Provider where

import Data.List (nub)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Ficus.Syntax.Name
import System.Directory (doesFileExist)
import System.FilePath (dropExtension, makeRelative, splitDirectories, (<.>), (</>))
import System.IO.Error (tryIOError)

data Source = Source {sourcePath :: FilePath, sourceText :: Text} deriving (Eq, Show)

type ModuleProvider m = ModuleId -> m (Either Text Source)

data PreludeSource = PreludeFromRoots | PreludeFile FilePath deriving (Eq, Show)

data ProviderConfig = ProviderConfig {sourceRoots :: [FilePath], preludeSource :: PreludeSource} deriving (Eq, Show)

-- Root overlap and duplicate files are reported, never resolved by map order.
fileProvider :: ProviderConfig -> ModuleProvider IO
fileProvider config owner = do
  let candidates = case (owner, preludeSource config) of
        (ModuleId ("Prelude" NE.:| []), PreludeFile file) -> [file]
        _ -> nub [root </> foldr1Path (map T.unpack (NE.toList parts)) <.> "ficus" | root <- sourceRoots config]
      ModuleId parts = owner
  existing <- filterMFiles candidates
  case existing of
    [] -> pure (Left ("module not found; searched " <> T.pack (show candidates)))
    [file] -> do
      result <- tryIOError (T.readFile file)
      pure (either (Left . T.pack . show) (Right . Source file) result)
    _ -> pure (Left ("multiple module files; configure unambiguous roots: " <> T.pack (show existing)))
  where
    filterMFiles [] = pure []
    filterMFiles (p : ps) = do
      exists <- doesFileExist p
      rest <- filterMFiles ps
      pure ([p | exists] ++ rest)
    foldr1Path [] = ""
    foldr1Path (p : ps) = foldl (</>) p ps

moduleIdentity :: FilePath -> FilePath -> Either Text ModuleId
moduleIdentity root file = case splitDirectories (dropExtension (makeRelative root file)) of
  p : ps | all (validModuleComponent . T.pack) (p : ps) -> Right (ModuleId (T.pack p NE.:| map T.pack ps))
  _ -> Left "module path components must be uppercase identifiers relative to the source root"

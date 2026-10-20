-- | Shared configuration for locating source modules and their dependencies.
module Ficus.ModuleOptions (ModuleOptions (..)) where

-- Empty roots use the calling driver's context: input directories for file
-- compilation, the working directory for an unloaded interactive session, or
-- workspace roots in the language server.
data ModuleOptions = ModuleOptions
  { sourceRoots :: [FilePath],
    libraryRoots :: [FilePath],
    preludeFile :: Maybe FilePath
  }
  deriving (Eq, Show)

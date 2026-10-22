-- | Independent compilation policies, selected by module metadata or the driver.
module Ficus.CompilationConfig
  ( CompilationConfig (..),
    defaultCompilationConfig,
    standaloneCompilationConfig,
    interactiveCompilationConfig,
  )
where

-- Each flag controls only its named policy. Recursive initialization safety,
-- implementation-member restrictions and type checking always remain enabled.
-- Warnings retain their ordinary behavior in every preset.
data CompilationConfig = CompilationConfig
  { checkTopLevelInitializers :: Bool,
    checkOrphanImplementations :: Bool,
    allowImportedImplementationOverrides :: Bool,
    rejectNonExhaustivePatterns :: Bool
  }
  deriving (Eq, Show)

defaultCompilationConfig :: CompilationConfig
defaultCompilationConfig =
  CompilationConfig
    { checkTopLevelInitializers = True,
      checkOrphanImplementations = True,
      allowImportedImplementationOverrides = False,
      rejectNonExhaustivePatterns = False
    }

standaloneCompilationConfig :: CompilationConfig
standaloneCompilationConfig = defaultCompilationConfig {checkTopLevelInitializers = False}

interactiveCompilationConfig :: CompilationConfig
interactiveCompilationConfig =
  standaloneCompilationConfig
    { checkOrphanImplementations = False,
      allowImportedImplementationOverrides = True
    }

-- | Target-independent backend passes. Each pass returns a checked boundary;
-- keep the unoptimized lowering API available for differential tests and tools.
module FicusBackend.Pipeline (optimizeProgram) where

import FicusBackend.Error qualified as E
import FicusBackend.Pass.Normalize
import FicusBackend.Pass.TailCalls
import FicusBackend.Runtime.Validate

optimizeProgram :: ValidatedProgram -> Either [E.BackendError] ValidatedProgram
optimizeProgram program = normalizedProgram <$> (normalizeProgram program >>= optimizeTailCalls)

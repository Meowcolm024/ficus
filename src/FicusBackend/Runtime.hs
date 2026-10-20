-- | Validated, closure-threaded execution. Entry points are numeric addresses;
-- libraries need no main declaration and execution performs no name lookup.
module FicusBackend.Runtime
  ( ValidatedProgram,
    validateProgram,
    validatedProgram,
    Executable,
    Instance,
    Entry,
    compileProgram,
    selectEntry,
    initialize,
    initializeWith,
    evaluateEntry,
    runProgram,
    Effects (..),
    StandardHandle (..),
    ioEffects,
    Value (..),
    Observation (..),
    observe,
    RuntimeError (..),
  )
where

import FicusBackend.Runtime.Compile
import FicusBackend.Runtime.Error
import FicusBackend.Runtime.Primitive (ioEffects)
import FicusBackend.Runtime.Validate
import FicusBackend.Runtime.Value

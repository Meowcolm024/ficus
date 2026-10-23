module Main (main) where

import Ficus.Builtin.MethodSpec qualified as BuiltinMethods
import Ficus.Builtin.RegistrySpec qualified as Builtin
import Ficus.CompileSpec qualified as Compile
import Ficus.Core.Spec qualified as Core
import Ficus.Error.ParserSpec qualified as ErrorParser
import Ficus.Error.PrettySpec qualified as ErrorPretty
import Ficus.Infer.CheckSpec qualified as Check
import Ficus.Infer.CorpusSpec qualified as Corpus
import Ficus.Infer.DeclarationSpec qualified as Declaration
import Ficus.Infer.ElaborateSpec qualified as Elaborate
import Ficus.Infer.FinalizeSpec qualified as Finalize
import Ficus.Infer.KindSpec qualified as Kind
import Ficus.Infer.RestrictionSpec qualified as Restriction
import Ficus.Infer.TypeSpec qualified as InferType
import Ficus.Parser.Spec qualified as Parser
import Ficus.Resolve.Spec qualified as Resolve
import Ficus.Resolve.WildcardSpec qualified as Wildcard
import FicusBackend.DriverSpec qualified as Driver
import FicusBackend.ExceptionSpec qualified as Exception
import FicusBackend.FileIOSpec qualified as FileIO
import FicusBackend.LazyArrowSpec qualified as LazyArrow
import FicusBackend.RecordPatternSpec qualified as RecordPattern
import FicusBackend.RefSpec qualified as Ref
import FicusBackend.Runtime.Spec qualified as Runtime
import FicusBackend.V1Spec qualified as V1
import FicusLsp.Spec qualified as Lsp
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  parser <- Parser.tests
  resolution <- Resolve.tests
  corpus <- Corpus.tests
  defaultMain
    ( testGroup
        "Ficus"
        [ testGroup "frontend" [Builtin.tests, BuiltinMethods.tests, parser, resolution, Wildcard.tests, Compile.tests, ErrorParser.tests, ErrorPretty.tests, InferType.tests, Core.tests, Restriction.tests, Finalize.tests, Kind.tests, Declaration.tests, Check.tests, corpus, Elaborate.tests],
          testGroup "backend" [Runtime.tests, Driver.tests, FileIO.tests, Exception.tests, LazyArrow.tests, RecordPattern.tests, Ref.tests, V1.tests],
          Lsp.tests
        ]
    )

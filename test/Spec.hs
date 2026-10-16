module Main (main) where

import Ficus.CompileSpec qualified as Compile
import Ficus.Error.ParserSpec qualified as ErrorParser
import Ficus.Error.PrettySpec qualified as ErrorPretty
import Ficus.Parser.Spec qualified as Parser
import Ficus.Resolve.Spec qualified as Resolve
import Ficus.Resolve.WildcardSpec qualified as Wildcard
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  parser <- Parser.tests
  resolution <- Resolve.tests
  defaultMain (testGroup "Ficus" [parser, resolution, Wildcard.tests, Compile.tests, ErrorParser.tests, ErrorPretty.tests])

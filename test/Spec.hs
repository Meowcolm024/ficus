module Main (main) where

import Ficus.Error.ParserSpec qualified as ErrorParser
import Ficus.Error.PrettySpec qualified as ErrorPretty
import Ficus.Parser.Spec qualified as Parser
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  parser <- Parser.tests
  defaultMain (testGroup "Ficus" [parser, ErrorParser.tests, ErrorPretty.tests])

module Main (main) where

import Ficus.Parser.Spec qualified as Parser
import Test.Tasty (defaultMain)

main :: IO ()
main = Parser.tests >>= defaultMain

module Game.Takuzu.SolverSpec where

import Data.List
import Data.Monoid
import Test.Hspec

import qualified Data.List.Match as LMatch

import Game.Takuzu.Parser
import Game.Takuzu.Solver

exampleRaw0 :: [] ([] Char)
exampleRaw0 =
  [ "br 12"
  , "    rr  br  "
  , "      r  b b"
  , "  br    r  b"
  , " r r        "
  , "b     r b b "
  , "  b b     b "
  , " r  br  r   "
  , "r    r      "
  , "r   r   bb  "
  , "  r     b   "
  , "      r   rb"
  , "  r  r      "
  ]

exampleRaw1 :: [] ([] Char)
exampleRaw1 =
  [ "br 12"
  , "  b b b     "
  , "b  r   r   b"
  , "     b     r"
  , " b     r  b "
  , "  bb   rr b "
  , "        r   "
  , " b  r      r"
  , "     b    r "
  , "bb  rb  b   "
  , "   r     r  "
  , "r r    rb  b"
  , "r   b     r "
  ]

areCompatible :: [[Maybe Cell]] -> [[Cell]] -> Bool
areCompatible inpBd outBd = and $ zipWith rowCompatible inpBd outBd
  where
    rowCompatible :: [Maybe Cell] -> [Cell] -> Bool
    rowCompatible xs ys = and $ zipWith cmp xs ys
    cmp Nothing _ = True
    cmp (Just b0) b1 = b0 == b1

expectSolution :: Int -> [[Cell]] -> Expectation
expectSolution n board = do
  let lengthMatches = LMatch.equalLength (replicate n ())
      expectRow :: [Cell] -> Expectation
      expectRow row = do
          blueCount `shouldBe` redCount
          (blueCount + redCount) `shouldBe` n
        where
          (Sum blueCount, Sum redCount) = foldMap go row
          go c
            | c == cBlue = (1,0)
            | c == cRed = (0,1)
            | otherwise = mempty

  -- verify that resulting board is of n x n.
  board `shouldSatisfy` lengthMatches
  board `shouldSatisfy` all lengthMatches
  let board' = transpose board
      noDup xs = xs `LMatch.equalLength` nub xs
  mapM_ expectRow board
  mapM_ expectRow (transpose board)
  board `shouldSatisfy` noDup
  board' `shouldSatisfy` noDup

spec :: Spec
spec =
  describe "solveBoard" $ do
    let mkExample name rawInp =
          specify name $ do
            Just (sz, bd) <- pure $ parseBoard (unlines rawInp)
            sz `shouldSatisfy` even
            sz `shouldSatisfy` (> 0)
            Just solved <- pure $ solveBoard sz bd
            expectSolution sz solved
            -- verify that we do build the solution repecting input board.
            (bd `areCompatible` solved) `shouldBe` True
    mkExample "example0" exampleRaw0
    mkExample "example1" exampleRaw1

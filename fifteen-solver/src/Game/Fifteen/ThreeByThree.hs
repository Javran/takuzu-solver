{-# LANGUAGE NamedFieldPuns #-}

module Game.Fifteen.ThreeByThree where

import Control.Applicative
import Control.Monad
import Control.Monad.ST
import Data.Bits
import qualified Data.DList as DL
import Data.Function
import qualified Data.HashSet as HS
import Data.HashTable.ST.Basic as HT
import qualified Data.IntSet as IS
import Data.List
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Vector as V
import Data.Word
-- import Game.Fifteen.Common

-- GB for general Board
import qualified Game.Fifteen.Common as GB -- GB for general Board
import Game.Fifteen.Types (Coord)
import qualified Game.Fifteen.Types as GB

{-
  a module specialized for solving 3x3 puzzles.
  Note that board size is not checked.
 -}

{-
  a 3x3 board is represented by a 36-bit integer,
  for lowest 4 bits to highest 4 bits, tiles are represented in row-major order:

  - 0-3: for coord (0,0)
  - 4-7: for coord (0,1)
  - 8-11: for coord (0,2)
  - 12-15: for coord (1,0)
  - etc.

  allowed tile digits are 0-7 and 15 (which stands for holes)

 -}
type Board3 = Word64

type Tile = Word8 -- only valid values are 0-7 and 15.

coordInRange :: Coord -> Bool
coordInRange (r, c) =
  r >= 0 && r < 3 && c >= 0 && c < 3

index :: Coord -> Int
index (r, c) = r * 3 + c

unindex :: Int -> Coord
unindex = (`quotRem` 3)

bdGet :: Board3 -> Coord -> Tile
bdGet bd coord = fromIntegral $ wide .&. 0xF
  where
    wide :: Word64
    wide = bd `shiftR` (4 * index coord)

holeIndex :: Board3 -> Int
holeIndex bd = go 0 bd
  where
    go i curBd =
      if curBd .&. 0xF == 0xF
        then i
        else go (i + 1) (shiftR curBd 4)

swapHole :: Board3 -> Coord -> Board3
swapHole bd0 coord = bd1
  where
    -- TODO: it's better that holeIndex is given to this function.
    holeBitInd = 4 * holeIndex bd0
    tileBitInd = 4 * index coord
    tileNum = bdGet bd0 coord
    holeMask :: Word64
    holeMask = shiftL 0xF holeBitInd
    bd1 =
      -- clear mask bits
      (bd0 .&. complement holeMask)
        .|.
        -- set tileNum to what used to be mask bit positions
        shiftL (fromIntegral tileNum) holeBitInd
        .|.
        -- set 0xF (mask) to what used to be tile positions
        shiftL 0xF tileBitInd

-- TODO: we could do a "rotateHole" that operate on 3 tiles,
-- but for now let's just settle on doing two swapHoles.
possibleMoves :: Board3 -> [(Coord, Board3)]
possibleMoves bd = do
  let holeInd = holeIndex bd
      hCoord = unindex holeInd
      movesInOneDir :: GB.Dir -> [(Coord, Board3)]
      movesInOneDir d = unfoldr go (hCoord, bd)
        where
          go (curHCoord, curBd) = do
            let hCoord' = GB.applyDir curHCoord d
                bd' = swapHole curBd hCoord'
                p = (hCoord', bd')
            guard $ coordInRange hCoord'
            pure (p, p)
  foldr
    (\d m -> m <> movesInOneDir d)
    []
    [GB.DUp, GB.DDown, GB.DLeft, GB.DRight]

fromBoard :: GB.Board -> Maybe Board3
fromBoard GB.Board {GB.bdSize, GB.bdTiles} = do
  guard $ bdSize == 3
  let tileToNum :: Maybe Int -> Word64
      tileToNum Nothing = 0xF
      tileToNum (Just v) = fromIntegral v
      encoded =
        foldr (.|.) 0 $
          zipWith
            (\offset n -> shiftL (tileToNum n) offset)
            [0, 4 ..]
            (V.toList bdTiles)
  pure encoded

toBoard :: Board3 -> GB.Board
toBoard bd = bd'
  where
    convert r c = if x == 0xF then Nothing else Just (fromIntegral x)
      where
        x = bdGet bd (r, c)
    tileSource = [[convert r c | c <- [0 .. 2]] | r <- [0 .. 2]]
    bd' = GB.mkBoard tileSource

solveBoard :: Board3 -> Board3 -> [[Coord]]
solveBoard goal initBoard = runST $ do
  visited <- HT.new
  let initQ = [(initBoard, [])]
  fix
    (\loop dl -> case dl of
       [] -> pure []
       (bd, path) : todos -> do
         if bd == goal
           then pure [path]
           else do
             r <- HT.lookup visited bd
             case r of
               Nothing -> do
                 HT.insert visited bd ()
                 let nextMoves :: [(Coord, Board3)]
                     nextMoves = possibleMoves bd
                 expanded <- fmap catMaybes <$> forM nextMoves $ \(coord, nextBd) -> do
                   r' <- HT.lookup visited nextBd
                   pure $ case r' of
                     Nothing -> Just (nextBd, coord : path)
                     Just () -> Nothing
                 loop (todos <> expanded)
               Just () ->
                 loop todos)
    initQ

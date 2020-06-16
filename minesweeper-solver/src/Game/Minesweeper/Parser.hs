{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Game.Minesweeper.Parser where

import Control.Applicative
import Control.Monad
import Data.Char
import qualified Data.Map.Strict as M
import Data.Maybe
import Text.ParserCombinators.ReadP

{-
  Input file format:
  <rows> <cols>
  followed by mine presentation.

  valid chars:
  - '?' for unknown
  - '1'..'8' for number tiles
  - ' ' or '_' for empty space
  - '*' for mines

  all lines end with newline.

 -}

type TmpBoard =
  ( -- rows, cols
    (Int, Int),
    -- num map
    M.Map (Int, Int) Int,
    -- mine map
    M.Map (Int, Int) Bool
  )

sampleRaw :: String
sampleRaw =
  unlines
    [ "7 7",
      "???????",
      "??1122?",
      "??1__1?",
      "?21_13?",
      "?1__1??",
      "?1122??",
      "???????"
    ]

parseBoard :: String -> Maybe TmpBoard
parseBoard raw = do
  [(v, "")] <- pure $ readP_to_S (boardP <* eof) raw
  pure v

rowsAndColsP :: ReadP (Int, Int)
rowsAndColsP = do
  rowsRaw <- munch1 isDigit
  _ <- char ' '
  colsRaw <- munch1 isDigit
  pure (read rowsRaw, read colsRaw)

tileP :: ReadP (Maybe Int, Maybe Bool)
tileP =
  ((Nothing, Nothing) <$ char '?')
    <++ ((Nothing, Just False) <$ (char ' ' <|> char '_'))
    <++ ( do
            c <- satisfy (\c -> c >= '1' && c <= '8')
            let n = ord c - ord '0'
            pure (Just n, Just False)
        )
    <++ ((Nothing, Just True) <$ char '*')

boardP :: ReadP TmpBoard
boardP = do
  let newlineP = void $ char '\n'
  dims@(rows, cols) <- rowsAndColsP <* newlineP
  (results :: [((Int, Int), (Maybe Int, Maybe Bool))]) <-
    concat
      <$> forM
        [0 .. rows -1]
        ( \row ->
            forM [0 .. cols -1] (\col -> ((row, col),) <$> tileP) <* newlineP
        )
  let numMap = M.fromList $ mapMaybe (\(c, (m, _)) -> (c,) <$> m) results
      tileMap = M.fromList $ mapMaybe (\(c, (_, m)) -> (c,) <$> m) results
  pure (dims, numMap, tileMap)

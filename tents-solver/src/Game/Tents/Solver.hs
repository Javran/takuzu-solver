{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Game.Tents.Solver where

import Control.Monad
import Data.Bifunctor
import Data.List
import qualified Data.Map.Merge.Strict as MMerge
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Semigroup
import qualified Data.Set as S
import qualified Data.Vector as V
import Game.Tents.Types
import System.Console.Terminfo

{-
  Note on use of Maybe.

  `Maybe` technically is not accurate in terms of what we express,
  as there are two kinds of exceptions that we might run into:

  - hard exception, meaning the Board we are working on is not solvable.
  - soft exception, meaning we cannot make progress using a specific tactic,
    which is fine given that we have other alternatives to try.

  Here we make the decision that if a tactic knows that it might not be able
  to make any progress, Nothing is returned. This allows us to be more aggressive
  at pruning search branches.

 -}

-- a Piece is a set of coord-cell assignments
-- that has to be applied to the board at the same time.
type Piece = M.Map Coord Cell

{-

  a `Candidates` is a set of alternative `Piece`
  meant to be applied to the same set of `Coord`s,

  - if a Candidates is an empty list, it's impossible to satisfy.
  - if a Candidates is a singleton list, it is the only possible set of assignment.

  Note that duplication is never verified and therefore must be maintained by
  contract on other functions.

 -}
type Candidates = [Piece]

-- using newtype to avoid confusion between this and Coord.
newtype Dir = Dir (Int, Int) -- diff by (row, col)

applyDir :: Dir -> Coord -> Coord
applyDir (Dir (dr, dc)) (r, c) = (r + dr, c + dc)

allDirs :: [Dir]
allDirs = Dir <$> [(0, -1), (0, 1), (-1, 0), (1, 0)]

{-

  Board keeps track of info necessary for solving the puzzle.

  Game rules are:

  Place tents in the empty squares in such a way that:

  (1) no two tents are adjacent, even diagonally
  (2) the number of tents in each row and column matches the numbers around the edge of the grid
  (3) it is possible to match tents to trees so that each tree is orthogonally adjacent to its own tent (but may also be adjacent to other tents).

  To address (2) for each unsolved row or column,
  we'll use bdTodoCandidates to store pieces that are (shallowly) consistent with rest of the board.

  To address (3), we have `bdTodoTrees` that keep track of possible tree-tent assignments for each tree,
  which is then used in `tryTree` to resolve tree candidates.

  Note that those rules have an important implication:
  if a cell is not adjacent vertically or horizontally to a tree,
  it is impossible for it to be a tent, therefore it must be an empty cell.
  This implication does not rely on current solving state (as tree is never introduced during solving),
  and therefore can be done during preprocessing.

  In this datatype, we establish an invariant:

   all empty cells that can be inferred from this implication will be inferred and put in bdCells

  this invariant allows us to never worry about cells that are not close to trees (and therefore must be empty)
  after this datatype is created.


  Note that it is also guaranteed that bdDims, bd{Row,Col}TentCounts never change after construction.

 -}
data Board = Board
  { bdDims :: (Int, Int) -- rows, cols
  , bdRowTentCounts :: V.Vector Int
  , bdColTentCounts :: V.Vector Int
  , bdCells :: !(M.Map Coord Cell)
  , -- transformed from brRowTentCounts + brColTentcounts,
    -- every unsatisfied row or column is supposed to have one entity here.
    bdTodoCandidates :: ![Candidates]
  , -- all trees whose tent assignment is not yet determined.
    -- TODO: probably this can also be encoded using bdTodoCandidates: we just need to ignore
    -- tree position and assign one neighbor Tent
    -- (Note: don't assign Empty, as there might be Tent meant to be bound to another tree.)
    -- TODO: turns out it is not straightforward merging two kinds of Candidates together:
    -- `Candidates` has an invariant that all containing `Piece`s must share the exact same set of Coord, which
    -- is not true for tree candidates.
    -- TODO: additionally, we might want to do some bookkeeping with a ADT, say Tag = Row Int | Col Int | Tree Coord
    -- this allows us to keep track of where a given Candidates is coming. This does not provide any additional power
    -- in terms of algorithm, but it does provide us with better debugging potentials.
    bdTodoTrees :: !(M.Map Coord [Coord])
  , bdTodoCoords :: !(S.Set Coord)
  }

-- TODO: verify that boards with impossible candidates result in Nothing.
mkBoard :: BoardRep -> Maybe Board
mkBoard
  BoardRep
    { brDims = bdDims@(rows, cols)
    , brBoard
    , brRowTentCounts = bdRowTentCounts
    , brColTentCounts = bdColTentCounts
    } = do
    let allCoords = S.fromList [(r, c) | r <- [0 .. rows -1], c <- [0 .. cols -1]]
        coordIsInside (r, c) = r >= 0 && r < rows && c >= 0 && c < cols
        bdTodoCoords = allCoords `S.difference` M.keysSet brBoard
        allTrees = M.keysSet $ M.filter (== Tree) brBoard
        simpleEmptyCoords = S.toList $ S.filter (not . nearTrees) bdTodoCoords
          where
            nearTrees c = any (\dir -> applyDir dir c `S.member` allTrees) allDirs
        bdCells = brBoard `M.union` M.fromList ((,Empty) <$> simpleEmptyCoords)
        genRowOrColCandidates coordss rowOrColTentCounts = do
          let result = zipWith go coordss rowOrColTentCounts
          -- ensure that every `Candidates` is not empty.
          guard $ all (not . null) result
          pure result
          where
            go coords count =
              fmap
                (M.filterWithKey (\coord _ -> isUnknown coord)
                   . M.fromList
                   . zip coords)
                filledLine
              :: Candidates
              where
                isUnknown coord = bdCells M.!? coord == Nothing
                filledLine = fillLine count $ fmap (bdCells M.!?) coords
    todoRowCandidates <-
      genRowOrColCandidates
        [[(r, c) | c <- [0 .. cols -1]] | r <- [0 ..]]
        (V.toList bdRowTentCounts)
    todoColCandidates <-
      genRowOrColCandidates
        [[(r, c) | r <- [0 .. rows -1]] | c <- [0 ..]]
        (V.toList bdColTentCounts)
    bdTodoTrees <- do
      let candidateTentCoords :: Coord -> Maybe [Coord]
          candidateTentCoords coord = do
            let result =
                  filter
                    (\coord' ->
                       let r = bdCells M.!? coord'
                        in r == Nothing || r == Just Tent)
                    . filter coordIsInside
                    $ fmap (\d -> applyDir d coord) allDirs
            guard $ not . null $ result
            pure result
      M.fromList
        <$> (forM (S.toList allTrees) $ \tCoord ->
               (tCoord,) <$> candidateTentCoords tCoord)
    {-
      Note that it's intentional that tentRepel is not performed on this initial board.
      This decision is made so that we can untie any test on tentRepel from this function.

      TODO: but this also means that we want an initial pass to call tentRepel on all existing tents.
     -}
    pure
      Board
        { bdDims
        , bdRowTentCounts
        , bdColTentCounts
        , bdCells
        , bdTodoCandidates =
            -- TODO: investigate whether it is desirable
            -- to merge candidates when their sets of coordinates are exactly the same.
            -- this might or might not happen when putting row and col candidates together.
            todoRowCandidates <> todoColCandidates
        , bdTodoTrees
        , bdTodoCoords
        }

{-
  Given a line (row or col) of incomplete board,
  complete that line nondeterministically.

  Line completion is done by replacing all Nothings with either Empty or Tent
  so that resulting line has # of tents specified
  and no two tents are adjacent to each other.
 -}
fillLine :: Int -> [Maybe Cell] -> [] [Cell]
fillLine tentCount = fillLineAux tentCount Empty []
  where
    {-
      fillLineAux n prevCell revAcc xs
      - n: # of tents required
      - prevCell
      - revAcc: accumulated result, in reverse order
      - xs: remaining current line
     -}
    fillLineAux n prevCell revAcc xs = case xs of
      [] ->
        -- end of list, verify, reverse and return.
        [reverse revAcc | n == 0]
      hd : tl -> case hd of
        Just v -> do
          let n' = if v == Tent then n -1 else n
          guard $ n' >= 0
          fillLineAux n' v (v : revAcc) tl
        Nothing ->
          -- it is always possible to place an empty one.
          fillLineAux n Empty (Empty : revAcc) tl
            -- when previous cell is a Tent, we are forced to place an Empty cell,
            -- otherwise two Tent will be adjacent to each other.
            -- when previous cell is Tree or Empty, next one is free to pick from Tent or Empty.
            <> do
              guard $ prevCell /= Tent
              guard $ n > 0
              fillLineAux (n -1) Tent (Tent : revAcc) tl

{-
  It is guaranteed that getCell will never access any field with Todo in name.
  We need this property so that this function can be called even during Board construction.
 -}
getCell :: Board -> Coord -> Maybe Cell
getCell Board {bdCells} coord = bdCells M.!? coord

-- TODO: to be tested
{- a tent "repels" nearby Nothings, making them all Empty -}
tentRepel :: Board -> Coord -> Maybe Board
tentRepel bd coord@(r, c) = case getCell bd coord of
  Just Tent -> do
    let Board {bdDims = (rows, cols), bdCells} = bd
        coordsToEmpty = do
          r' <- [max 0 (r -1) .. min (rows -1) (r + 1)]
          c' <- [max 0 (c -1) .. min (cols -1) (c + 1)]
          let coord' = (r', c')
          guard $ getCell bd coord' == Nothing
          pure coord'
        bdCells' = M.union (M.fromList $ fmap (,Empty) coordsToEmpty) bdCells
        bdResult = bd {bdCells = bdCells'}
    foldM tidyBoard bdResult coordsToEmpty
  _ -> pure bd

{-
  remove candidates that are inconsistent with one particular cell of the board.
 -}
tidyBoard :: Board -> Coord -> Maybe Board
tidyBoard bd coord = case getCell bd coord of
  Nothing -> Just bd
  Just Tree -> Just bd
  Just cell -> do
    -- here cell is either Empty or Tent
    let Board {bdTodoCandidates, bdTodoTrees} = bd
        updateCandidates :: Candidates -> Maybe Candidates
        updateCandidates [] =
          -- must be non-empty
          Nothing
        updateCandidates cs@(p : _) = do
          -- only need to examine one piece as the key set is shared in a single `Candidates`.
          -- Note: `p` should never be used inside sub-expressions, is there a way we can prevent this kind of mistakes?
          case p M.!? coord of
            Nothing -> Just cs
            Just _ -> do
              let updatePiece :: Piece -> Maybe Piece
                  updatePiece pc =
                    if pc M.! coord == cell
                      then -- remove record of that cell since this value is now set.
                        Just $! M.delete coord pc
                      else -- remove this piece from candidate as it is no longer consistent.
                        Nothing
              -- if we have filtered out all candidates, this board is impossible to solve.
              cs'@(_ : _) <- pure $ mapMaybe updatePiece cs
              pure cs'
        bdTodoTrees' :: M.Map Coord [Coord]
        bdTodoTrees' =
          if cell == Empty
            then -- an Empty cell cannot be paired with a tree.

              let treeCoords = fmap (\d -> applyDir d coord) allDirs
               in foldr (M.adjust (delete coord)) bdTodoTrees treeCoords
            else bdTodoTrees
        -- True only if a `Candidates` is a singleton list of an empty Map.
        satCandidates [x] = M.null x
        satCandidates _ = False
    bdTodoCandidates' <-
      filter (not . satCandidates)
        <$> mapM updateCandidates bdTodoCandidates
    guard $ all (not . null) bdTodoTrees'
    pure $ bd {bdTodoCandidates = bdTodoCandidates', bdTodoTrees = bdTodoTrees'}

{-
  set coord to a cell value, internal use only (for now),
  since we don't have much check on things on this function.
 -}
setCoordInternal :: Coord -> Cell -> Board -> Maybe Board
setCoordInternal coord cell bd@Board {bdCells, bdTodoCoords} = do
  bd' <-
    tidyBoard
      bd
        { bdCells = M.insert coord cell bdCells
        , bdTodoCoords = S.delete coord bdTodoCoords
        }
      coord
  case cell of
    Tent -> tentRepel bd' coord
    _ -> pure bd'

fillPiece :: Piece -> Board -> Maybe Board
fillPiece p bd = do
  let Board {bdCells} = bd
      (pExisting, pNew) = M.partitionWithKey (\coord _ -> M.member coord bdCells) p
  -- ideally pExisting should be empty, but if there is any kind of overlap,
  -- bdCells must agree.
  guard $ pExisting == M.restrictKeys bdCells (M.keysSet pExisting)
  foldM (\curBd (coord, cell) -> setCoordInternal coord cell curBd) bd (M.toList pNew)

{-
  Given a Board and a list of Boards directly derived from it,
  find and set mappings common among all of them.
  This function fails when no common mapping can be found.
 -}
resolveCommonMappings :: Board -> [Board] -> Maybe Board
resolveCommonMappings bd nextBds = do
  let bdCells0 = bdCells bd
      mergeCommon :: M.Map Coord Cell -> M.Map Coord Cell -> M.Map Coord Cell
      mergeCommon =
        MMerge.merge
          MMerge.dropMissing
          MMerge.dropMissing
          (MMerge.zipWithMaybeMatched (\_k x y -> x <$ guard (x == y)))
      newMappings =
        -- for each viable Piece, extract newly added mappings.
        fmap ((\s -> s `M.difference` bdCells0) . bdCells) nextBds
      commonMappings =
        -- this is safe since we know newMappings is non-empty.
        foldl1' mergeCommon newMappings
  -- if we don't have anything in newMappings,
  -- there is no progress to be made.
  -- this is a "soft" exception but we want it to fail to reduce branching factor on searches.
  guard $ not . null $ newMappings
  fillPiece commonMappings bd


-- try all possible Pieces of a Candidates,
-- and set cells that are common among all those Pieces.
tryCandidates :: Candidates -> Board -> Maybe Board
tryCandidates cs bd = do
  -- it is expected that some will fail but the result should not be empty
  -- if the input Board is solvable.
  cs'@(_ : _) <- pure $ mapMaybe (\p -> fillPiece p bd) cs
  resolveCommonMappings bd cs'

{-
  Try placing a tent near a tree.
  Note that there is almost no input verification so
  - whether input coordinates are actually near each other is not checked.
  - whether tree coordinate actually present in bdTodoTrees is not checked.
 -}
tryTreeCoord :: Coord -> Coord -> Board -> Maybe Board
tryTreeCoord treeCoord tentCoord bd = do
  bd'@Board {bdTodoTrees = todoTrees'} <- setCoordInternal tentCoord Tent bd
  -- bd' should have been called with tidyBoard in setCoordInternal
  pure bd' {bdTodoTrees = M.delete treeCoord todoTrees'}

tryTree :: Coord -> [Coord] -> Board -> Maybe Board
tryTree treeCoord tentAltCoords bd = do
  cs'@(_ : _) <- pure $ mapMaybe (\tentCoord -> tryTreeCoord treeCoord tentCoord bd) tentAltCoords
  resolveCommonMappings bd cs'

-- Provide a digest for a Board to tell if the board has been changed by some tactics
-- the digest is a short summary of "how big" are the the todo fields.
bdProgress :: Board -> (Int, Int, Int)
bdProgress Board {bdTodoCoords, bdTodoCandidates, bdTodoTrees} =
  ( S.size bdTodoCoords
  , getSum ((foldMap . foldMap) (Sum . M.size) bdTodoCandidates)
  , getSum ((foldMap . foldMap) (Sum . length) bdTodoTrees)
  )


{-
  This will be the entry point of the solver.
  We first work on bdTodoTrees (tryTree) since it's relatively cheap to trial and error,
  and only proceed to the more expensive tactic involving bdTodoCandidates if tryTree cannot make any progress.
 -}
solve :: Board -> Maybe Board
solve bd = do
  -- TOOD: might be able to refactor solve and slowSolve.
  let Board {bdTodoTrees, bdTodoCoords} = bd
  if S.null bdTodoCoords
    then Just bd
    else do
      let progress = bdProgress bd
          -- TODO: we might consider merging `solve` and `slowSolve` into one function
          -- that mixes bdTodoCandidates and bdTodoTrees in one sorted list,
          -- so that we don't run into an awkward situation that all not-yet-resolved trees
          -- must be attempted when there is some obvious and simple row/col candidate available.
          sortedTrees = sortOn (length . snd) $ M.toList bdTodoTrees
      nextBds <- mapM (\(treeCoord, alts) -> tryTree treeCoord alts bd) sortedTrees
      let updated = filter (\curBd -> bdProgress curBd /= progress) nextBds
      case updated of
        [] -> slowSolve bd
        nextBd : _ -> solve nextBd

-- a slow but working solver: it tries every `Candidates` until it's solved
-- or no progress can be made on the board.
slowSolve :: Board -> Maybe Board
slowSolve bd = do
  let Board {bdTodoCandidates, bdTodoCoords} = bd
  if S.null bdTodoCoords
    then Just bd
    else do
      let progress = bdProgress bd
          sortedCandidates =
            sortOn
              -- ascending length, then descending size.
              -- the idea is to try "large pieces", which is more likely
              -- to resolve into more known common mappings.
              (\xs -> (length xs, - M.size (head xs)))
              bdTodoCandidates
      -- try to resolve candidates in sorted order
      nextBds <- mapM (\cs -> tryCandidates cs bd) sortedCandidates
      let updated = filter (\curBd -> bdProgress curBd /= progress) nextBds
      case updated of
        [] -> Just bd
        nextBd : _ ->
          -- call into less expensive tactics which might now make better progress.
          solve nextBd

pprBoard :: Terminal -> Board -> IO ()
pprBoard
  term
  bd@Board
    { bdDims
    , bdTodoTrees
    , bdRowTentCounts
    , bdColTentCounts
    , bdTodoCandidates
    } = do
    let (rows, cols) = bdDims
        (fg, bg) =
          fromMaybe (const id, const id) $
            (,)
              <$> getCapability term (withForegroundColor @TermOutput)
              <*> getCapability term (withBackgroundColor @TermOutput)
    putStrLn $ "(rows,cols): " <> show bdDims
    let renderCell getCell' (r, c) =
          case getCell' (r, c) of
            Nothing -> termText "?"
            Just Empty -> bg White $ termText " "
            Just Tree -> bg Green $ fg White $ termText "R"
            Just Tent -> bg Blue $ fg White $ termText "E"

    forM_ [0 .. rows -1] $ \r -> do
      let rendered =
            foldMap (renderCell (getCell bd) . (r,)) [0 .. cols -1]
              <> termText (show (bdRowTentCounts V.! r))
              <> termText "\n"
      runTermOutput term rendered
    let tr n =
          -- let's not worry about what to do when n > 9 for now, it's very rare.
          if n > 9 then "-" else show n
    putStrLn (concatMap tr $ V.toList bdColTentCounts)
    putStrLn "Tree candidates counts:"
    forM_ [0 .. rows -1] $ \r -> do
      forM_ [0 .. cols -1] $ \c ->
        putStr $
          case getCell bd (r, c) of
            Nothing -> "?"
            Just Empty -> " "
            Just Tree ->
              case bdTodoTrees M.!? (r, c) of
                Nothing ->
                  -- this can only happen when the tree is question
                  -- is considered solved therefore discharged.
                  "!"
                Just v -> show (length v)
            Just Tent -> "E"
      putStrLn ""
    forM_ (zip [0 :: Int ..] bdTodoCandidates) $ \(idx, cs) -> do
      let coords =
            -- the invariant is that pieces in `cs` share the same set of coordinates.
            case cs of
              v : _ | v' <- M.keys v, not . null $ v' -> v'
              _ -> error "invalid: candidates or pieces cannot be empty"
          ( (Just (Min minRow), Just (Max maxRow))
            , (Just (Min minCol), Just (Max maxCol))
            ) =
              foldMap (let f v = (Just (Min v), Just (Max v)) in bimap f f) coords

      putStrLn $
        show idx <> ": " <> show (length cs) <> " pieces, with range: "
          <> show (minRow, minCol)
          <> "-"
          <> show (maxRow, maxCol)
      forM_ cs $ \p -> do
        if minRow == maxRow
          then do
            forM_ [minRow .. maxRow] $ \r -> do
              let rendered =
                    termText "  "
                      <> foldMap (renderCell (\coord -> p M.!? coord) . (r,)) [minCol .. maxCol]
                      <> termText "\n"
              runTermOutput term rendered
            putStrLn ""
          else do
            -- transpose before printing out to make it easier to compare candidates against each other.
            putStrLn "  (transposed)"
            forM_ [minCol .. maxCol] $ \c -> do
              let rendered =
                    termText "  "
                      <> foldMap (renderCell (\coord -> p M.!? coord) . (,c)) [minRow .. maxRow]
                      <> termText "\n"
              runTermOutput term rendered
            putStrLn ""

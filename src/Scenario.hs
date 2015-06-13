-----------------------------------------------------------------------------
--
-- Module      :  Scenario
-- Copyright   :
-- License     :  AllRightsReserved
--
-- Maintainer  :  tpajenka@foo
-- Stability   :
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

module Scenario where

import           Control.Monad
import           Data.Array
import           Data.Maybe

-- | @Features@ are the doodads that can be placed in a scenario.
data Feature = Wall    -- ^ static wall
             | Floor   -- ^ empty floor
             | Object  -- ^ object that can be moved around
             | Target  -- ^ target where objects should be shifted on
             | TargetX -- ^ target occupied by an object
             deriving (Eq, Enum, Show, Read)

-- | Valid player move directions.
data PlayerMovement = MLeft | MRight | MUp | MDown deriving (Eq, Enum, Show, Read)

-- | Reasons why a requested player move can be invalid
data DenyReason = PathBlocked  -- ^ The target @Feature@ can neither be walked on nor shifted
                | ShiftBlocked -- ^ The target @Feature@ can be shifted but the after next coordinate is blocked
                | OutsideWorld -- ^ The target coordinate resides outside of the scenario
                deriving (Eq, Enum, Show, Read)

-- | @Feature@ can be walked on?
walkable :: Feature -> Bool
walkable Floor  = True
walkable Target = True
walkable _      = False

-- | @Feature@ can be shifted onto other @Features@?
shiftable :: Feature -> Bool
shiftable Object  = True
shiftable TargetX = True
shiftable _       = False

-- | Other @Features@ can be shifted onto this @Feature@?
targetable :: Feature -> Bool
targetable Floor   = True
targetable Target  = True
targetable TargetX = False
targetable _       = False

-- | What you get if you mix two @Feature@s.
combineFeatures :: Feature        -- ^ previous @Feature@
                -> Feature        -- ^ new @Feature@
                -> (Feature, Int) -- ^ the combined @Feature@ and the change of unoccupied targets
combineFeatures Target  Object  = (TargetX, -1)
combineFeatures Target  TargetX = (TargetX,  0)
combineFeatures Target  _       = (Target,   0)
combineFeatures TargetX Object  = (TargetX,  0)
combineFeatures TargetX TargetX = (TargetX,  0)
combineFeatures TargetX _       = (Target,   1)
combineFeatures _       new     = (new,      0)

-- | Scenario coordinates @(x, y)@.
type Coord = (Int, Int)

-- | Coordinate movement.
moveCoordinate :: PlayerMovement -- ^ move direction
               -> Coord          -- ^ original coordinate
               -> Coord          -- ^ target coordinate
moveCoordinate MLeft  (x, y) = (x-1, y)
moveCoordinate MRight (x, y) = (x+1, y)
moveCoordinate MUp    (x, y) = (x, y-1)
moveCoordinate MDown  (x, y) = (x, y+1)

-- | A @Scenario@ is a possibly bounded world of 'Feature's.
--   Each feature coordinate may be changed.
--   
--  === Minimal complete definition
--  > getFeature', 'setFeature'
--  Definition of 'isInside' is recommended.
class Scenario sc where
  -- | Test if a coordinate is within the world.
  isInside :: sc -> Coord -> Bool
  isInside sc = not . isNothing . getFeature sc
  -- | Get the @Feature@ at the specified coordinates.
  --   Returns 'Nothing' if the coordinates are inccassible.
  getFeature :: sc -> Coord -> Maybe Feature
  -- | Set the @Feature@ at the specified coordinates.
  --   Returns 'Nothing' if the coordinates are inccassible, the updated scenario otherwise.
  setFeature :: sc -> Coord -> Feature -> Maybe sc
  -- | Changes the @Feature@ at the specified coordinates depending on the current @Feature@.
  --   Returns 'Nothing' if the coordinates are inccassible, the updated scenario otherwise.
  modifyFeature :: sc -> Coord -> (Feature -> Feature) -> Maybe sc
  modifyFeature sc c f = do ft <- getFeature sc c
                            setFeature sc c (f ft)

-- | 'Scenario' instance with an underlying dense matrix.
newtype MatrixScenario = MatrixScenario { matrix :: Array Coord Feature } deriving(Eq, Show)


instance Scenario MatrixScenario where
  isInside (MatrixScenario mat) c = inRange (bounds mat) c
  getFeature sc@(MatrixScenario mat) c = if isInside sc c
                                           then return $ mat!c
                                           else Nothing
  setFeature sc@(MatrixScenario mat) c ft = if isInside sc c
                                           then return $ MatrixScenario $ mat//[(c, ft)]
                                           else Nothing


-- | Single character representation of a @Feature@.
showFeature :: Feature -> Char
showFeature Wall    = '#'
showFeature Floor   = ' '
showFeature Object  = '$'
showFeature Target  = '.'
showFeature TargetX = '+'

-- | Converts a @MatrtixScenario@ into a easily readable string.
showScenario :: MatrixScenario -> String
showScenario (MatrixScenario mat) = let ((xl, yl), (xh, yh)) = bounds mat
                                    in do r <- [yl..yh]
                                          [ (showFeature . (!) mat) (c, r) | c <- [xl..xh] ] ++ "\n"

-- | A @ScenarioState@ stores the current state of a game.
data ScenarioState sc = ScenarioState
                        { playerCoord  :: Coord -- ^ current player coordinates
                        , scenario     :: sc    -- ^ current 'Scenario'
                        , emptyTargets :: Int   -- ^ the amount of unoccupied targets within the scenario
                        } deriving (Eq, Show, Read)

-- | Tests if the @Scenario@ of a @ScenarioState@ is finished.
isWinningState :: ScenarioState sc -> Bool
isWinningState st = emptyTargets st == 0

-- | A storage for everything that changed within a 'ScenarioState'.
-- === See also
-- > 'askPlayerMove', 'updateScenario'
data ScenarioUpdate = ScenarioUpdate
                      { changedFeatures :: [(Coord, Feature)] -- ^ a list of all changed @Features@, each coordinate is present only once
                                                              --   and the corresponding @Feature@ is the @Feature@ after the update
                      , newPlayerCoord  :: Coord              -- ^ the player coordinates after the update
                      , newEmptyTargets :: Int                -- ^ the total amount of unoccupied targets after the update
                      } deriving (Eq, Show, Read)

-- | Tests whether a player move can be performed and computes the result.
--   Returns a @Left 'DenyReason'@ if the move is not possible and a
--   @Right 'ScenarioUpdate'@ with the resulting changes otherwise.
-- === See also
-- > 'updateScenario'
askPlayerMove :: Scenario sc => ScenarioState sc -> PlayerMovement -> Either DenyReason ScenarioUpdate
askPlayerMove scs dir =
    do let sc = scenario scs
           p = playerCoord scs                           -- player coord
           tp = moveCoordinate dir p                     -- move target coord
       if isInside sc tp
         then do let ft = fromJust $ getFeature sc tp    -- move target feature
                     cs = moveCoordinate dir tp          -- shift target coord
                     fs :: Maybe Feature
                     fs = getFeature sc cs               -- shift target feature
                 if walkable ft
                   then -- Move the player onto the target Feature
                        Right $ ScenarioUpdate { changedFeatures = []
                                               , newPlayerCoord = tp
                                               , newEmptyTargets = emptyTargets scs }
                   else -- The target Feature cannot be walked on, but it may be shifted away
                        case (shiftable ft, (not . isNothing) fs && targetable (fromJust fs)) of
                             (True, True)  -> Right $               -- perform a shift and move the player
                                  let (ft1, targetChange1) = combineFeatures ft            Floor
                                      (ft2, targetChange2) = combineFeatures (fromJust fs) ft
                                  in ScenarioUpdate { changedFeatures = [(tp, ft1), (cs, ft2)]
                                                    , newPlayerCoord = tp
                                                    , newEmptyTargets = emptyTargets scs + targetChange1 + targetChange2 }
                             (True, False) -> Left ShiftBlocked     -- Shift target space is blocked
                             _ -> Left PathBlocked                  -- Feature cannot be shifted
         else Left OutsideWorld


-- | Performs a @ScenarioUpdate@ on the given @ScenarioState@.
--   The update is alqays possible if the @ScenarioUpdate@ has been computed via
--   'askPlayerMove' on the same @ScenarioState@. An error may occur otherwise.
-- === See also
-- > 'askPlayerMove'
updateScenario :: Scenario sc => ScenarioState sc -> ScenarioUpdate -> ScenarioState sc
updateScenario sc u = sc
            { playerCoord = newPlayerCoord u
            , scenario = case foldM (uncurry . setFeature) (scenario sc)  (changedFeatures u) of
                              Just sc' -> sc'
                              Nothing  -> error $ "invalid update step " ++ show u -- Nothing -> sc
            , emptyTargets = newEmptyTargets u
            }



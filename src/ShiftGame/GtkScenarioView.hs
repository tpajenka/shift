{-# LANGUAGE BangPatterns, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, InstanceSigs, TemplateHaskell #-}
-----------------------------------------------------------------------------
--
-- Module      :  ShiftGame.GTKScenarioView
-- Copyright   :  (c) 2015, Thomas Pajenkamp
-- License     :  BSD3
--
-- Maintainer  :  tpajenka
-- Stability   :
-- Portability :
--
-- | GTK based view for game model
--
-----------------------------------------------------------------------------

module ShiftGame.GtkScenarioView where

import           Control.Concurrent
import           Control.Lens
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State.Lazy
import           Data.List (partition)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Graphics.Rendering.Cairo (liftIO)
import qualified Graphics.Rendering.Cairo as Cairo
import qualified Graphics.Rendering.Cairo.Internal as Cairo (surfaceStatus)
import           Graphics.UI.Gtk hiding (get, set, rectangle)
import           System.Directory (doesFileExist)
import           System.FilePath (pathSeparator)

import LensNaming
--import ShiftGame.Helpers
import ShiftGame.Scenario
import ShiftGame.ScenarioController


data MovementMode = MovementEnabled | MovementDisabled deriving (Bounded, Eq, Show, Read, Enum)

-- | When a scenario change is scheduled, stores the thread id of the stalling thread.
--   The thread should only execute the scheduled switch if the thread id remains the same when the change is due.
data ScenarioChangeMode = NoChangeStalled | ChangeStalled { stallingThreadId :: ThreadId, stalledScenarioId :: ScenarioId } deriving (Eq, Show)
$(makeLensPrefixLenses ''ScenarioChangeMode)
$(makePrisms ''ScenarioChangeMode)


data UserInputControl = UserInputControl { keysLeft   :: [KeyVal] -- ^ keys (alternatives) to trigger a "left" movement
                                         , keysRight  :: [KeyVal] -- ^ keys (alternatives) to trigger a "right" movement
                                         , keysUp     :: [KeyVal] -- ^ keys (alternatives) to trigger an "up" movement
                                         , keysDown   :: [KeyVal] -- ^ keys (alternatives) to trigger a "down" movement
                                         , keysQuit   :: [KeyVal] -- ^ keys (alternatives) to exit the game
                                         , keysUndo   :: [KeyVal] -- ^ keys (alternatives) to undo a single step
                                         , keysRedo   :: [KeyVal] -- ^ keys (alternatives) to redo a single step
                                         , keysReset  :: [KeyVal] -- ^ keys (alternatives) to restart the level
                                         , keysNext   :: [KeyVal] -- ^ keys (alternatives) to advance to next level
                                         , keysPrev   :: [KeyVal] -- ^ keys (alternatives) to revert to previous level
                                         , keysLoad   :: [KeyVal] -- ^ keys (alternatives) to show "open level file" dialog
                                         , movementMode  :: MovementMode -- ^ what user interactions are currently possible
                                         } deriving (Eq, Show)
$(makeLensPrefixLenses ''UserInputControl)

data GameSettings sc = GameSettings { scenarioSettings :: ScenarioSettings sc
                                    , userInputControl :: UserInputControl
                                    , stalledScenarioChange :: ScenarioChangeMode
                                    } deriving (Eq, Show)
$(makeLensPrefixLenses ''GameSettings)


{-
TextView based view
-}

-- | 'UpdateListener' to display the current level on a text field in ASCII characters.
data TextViewUpdateListener = TextViewUpdateListener TextBuffer

instance UpdateListener TextViewUpdateListener IO MatrixScenario where
  notifyUpdate :: TextViewUpdateListener -> ScenarioUpdate -> ReaderT (ScenarioState MatrixScenario) IO TextViewUpdateListener
  notifyUpdate l@(TextViewUpdateListener tBuffer) _ = do
      scState <- ask -- todo: player position
      let levelStrWithPlayer = showScenarioWithPlayer (scenario scState) (playerCoord scState)
      lift $ postGUIAsync (textBufferSetByteString tBuffer levelStrWithPlayer)
      return l
  notifyNew :: TextViewUpdateListener -> ReaderT (ScenarioState MatrixScenario) IO TextViewUpdateListener
  notifyNew l@(TextViewUpdateListener tBuffer) = do
      scState <- ask -- todo: player position
      let levelStrWithPlayer = showScenarioWithPlayer (scenario scState) (playerCoord scState)
      lift $ postGUIAsync (textBufferSetByteString tBuffer levelStrWithPlayer)
      return l
  notifyWin :: TextViewUpdateListener -> ReaderT (ScenarioState MatrixScenario) IO TextViewUpdateListener
  notifyWin l = return l

-- | Creates a @TextViewUpdateListener@ for the given @TextBuffer@
createTextViewLink :: TextBuffer -> TextViewUpdateListener
createTextViewLink = TextViewUpdateListener


{-
Graphics View
-}

-- | Container for raw images of single features and the player.
data ImagePool = ImagePool { featureMap :: M.Map Feature Cairo.Surface -- ^ map containing images for raw features
                           , playerMap  :: M.Map Feature Cairo.Surface -- ^ map containing images for player onto feature, if special
                           , playerImg  :: Cairo.Surface               -- ^ player image to draw onto feature if not contained in playerMap
                           }
$(makeLensPrefixLenses ''ImagePool)

-- | 'UpdateListener' for a 'DrawingArea', draws and updates the @DrawingArea@ with the current level on each player action.
data CanvasUpdateListener sc = CanvasUpdateListener { bufferedImages :: ImagePool            -- ^ available images to draw onto canvas
                                                    , drawCanvas     :: DrawingArea          -- ^ connected @DrawingArea@ serving as canvas
                                                    , surfaceRef     :: MVar Cairo.Surface   -- ^ reference to Cairo image of currently drawed scenario
                                                    , lowScenarioBnd :: (Int, Int)           -- ^ lower /(x, y)/ bounds of current scenario
                                                    }
$(makeLensPrefixLenses ''CanvasUpdateListener)

instance (Scenario sc) => UpdateListener (CanvasUpdateListener sc) IO sc where
  notifyUpdate :: (CanvasUpdateListener sc) -> ScenarioUpdate -> ReaderT (ScenarioState sc) IO (CanvasUpdateListener sc)
  notifyUpdate l@(CanvasUpdateListener imgs widget sfcRef lowBnd) u = do
      sfc <- lift $ readMVar sfcRef
      invalRegion <- lift $ Cairo.renderWith sfc (scenarioUpdateRender imgs u lowBnd)
      lift $ postGUIAsync (widgetQueueDrawRegion widget invalRegion)
      return l
  notifyNew :: (CanvasUpdateListener sc) -> ReaderT (ScenarioState sc) IO (CanvasUpdateListener sc)
  notifyNew l@(CanvasUpdateListener imgs widget sfcRef _) = do
      scs <- ask
      let ((lx,ly), (hx, hy)) = getScenarioBounds (scenario scs)
          xSpan = (hx-lx + 1) * 48
          ySpan = (hy-ly + 1) * 48
      sfc <- lift $ takeMVar sfcRef
      -- create new surface if dimension changed
      w <- lift $ Cairo.imageSurfaceGetWidth sfc
      h <- lift $ Cairo.imageSurfaceGetHeight sfc
      nextSfc <- if (w /= xSpan || h /= ySpan) 
        then lift $ do newSfc <- Cairo.createImageSurface Cairo.FormatARGB32 xSpan ySpan
                       return newSfc
        else return sfc
      lift $ putMVar sfcRef nextSfc    
      lift $ postGUIAsync (do
          -- find parent window, this way is not universal but should suffice in this use case
          -- further details can be found in the GTK documentation for gtk_widget_get_toplevel
          mbParentWindow <- widgetGetAncestor widget gTypeWindow
          -- resize widget and possibly parent window
          when (w /= xSpan || h /= ySpan) (widgetSetSizeRequest widget xSpan ySpan
               -- resize window to smallest possible size
               >> maybe (return ()) (\w -> windowResize (castToWindow w) 1 1)
               mbParentWindow)
          -- redraw scenario surface
          drawScenario imgs nextSfc scs
          widgetQueueDraw widget)
      return $ set lensLowScenarioBnd (lx,ly) l
  notifyWin :: (CanvasUpdateListener sc) -> ReaderT (ScenarioState sc) IO (CanvasUpdateListener sc)
  notifyWin l = return l


-- | RGBA color components.
type CairoColor = (Double, Double, Double, Double)

-- | Renders the whole content of a @ScenarioState@ onto a surface.
scenarioRender :: Scenario sc => ImagePool -> ScenarioState sc -> Cairo.Render ()
scenarioRender imgs scs = do
    -- paint background
    (cx1, cy1, cx2, cy2) <- Cairo.clipExtents
    Cairo.rectangle cx1 cy1 cx2 cy2
    Cairo.setSourceRGB 0.0 0.0 0.0
    Cairo.fill
    -- paint scenario map
    let (l@(lx,ly), (hx, hy)) = getScenarioBounds (scenario scs)
    sequence_ $ map (drawFeature imgs l) $
        [((x, y), fromMaybe Wall $ getFeature (scenario scs) (x, y)) | x <- [lx..hx], y <- [ly..hy]]
    -- paint player
    let pCoord = playerCoord scs
    void $ drawFeatureWithPlayer imgs l (pCoord, fromMaybe Wall $ getFeature (scenario scs) pCoord)
                              
-- | Renders the changes of a @ScenarioUpdate@ onto a surface.
scenarioUpdateRender :: ImagePool                    -- ^ single sprites
                     -> ScenarioUpdate               -- ^ new scenario state
                     -> (Int, Int)                   -- ^ lower /(x, y)/ scenario bounds
                     -> Cairo.Render (Cairo.Region)  -- ^ surface areas that changed and should be invalidated
scenarioUpdateRender imgs u lowCoords = do
    -- overpaint given coordinates
    let pc = newPlayerCoord u
        -- find current player position in update list
        (pCoord, pNotCoord) = partition (\(c, _) -> c == pc) (changedFeatures u)
    inval  <- sequence $ map (drawFeature imgs lowCoords) pNotCoord
    inval' <- sequence $ map (drawFeatureWithPlayer imgs lowCoords) pCoord
    Cairo.regionCreateRectangles (inval ++ inval')
        
-- | Renders a single feature onto a surface.
drawFeature :: ImagePool           -- ^ single raw sprites
            -> (Int, Int)          -- ^ lower /(x, y)/ scenario bounds
            -> (Coord, Feature)    -- ^ the level coordinates and the feature to draw on those coordinates
            -> Cairo.Render Cairo.RectangleInt  -- ^ the surface region that changed
drawFeature imgs (lx, ly) ((x, y), ft) = do
    let xc = (x - lx) * 48
        yc = (y - ly) * 48
        xcd = fromIntegral xc :: Double
        ycd = fromIntegral yc :: Double
    case M.lookup ft (featureMap imgs) of
         Just sfc -> do w <- liftM fromIntegral $ Cairo.imageSurfaceGetWidth sfc  :: Cairo.Render Double
                        h <- liftM fromIntegral $ Cairo.imageSurfaceGetHeight sfc :: Cairo.Render Double
                        Cairo.save >> Cairo.rectangle xcd ycd (min 48 w) (min 48 h) >> Cairo.clip
                        Cairo.setSourceSurface sfc xcd ycd >> Cairo.paint >> Cairo.restore
         Nothing -> renderEmptyRect xcd ycd 48 48 (1.0, 0.0, 1.0, 1.0)    -- magenta fallback rectangle
    return $ Cairo.RectangleInt xc yc 48 48

-- | Renders a single feature including the player onto a surface.
drawFeatureWithPlayer :: ImagePool           -- ^ single raw sprites
                      -> (Int, Int)          -- ^ lower /(x, y)/ scenario bounds
                      -> (Coord, Feature)    -- ^ the level coordinates and the feature to draw on those coordinates
                      -> Cairo.Render Cairo.RectangleInt  -- ^ the surface region that changed
drawFeatureWithPlayer imgs l@(lx, ly) item@((x, y), ft) = do
    let xc = (x - lx) * 48
        yc = (y - ly) * 48
        xcd = fromIntegral xc
        ycd = fromIntegral yc
    img <- case M.lookup ft (playerMap imgs) of
                -- draw combined "Feature+Player" image, if available
                Just sfc -> return sfc
                -- draw raw feature and paint player image on top
                Nothing -> drawFeature imgs l item >> return (playerImg imgs)
    w <- liftM fromIntegral $ Cairo.imageSurfaceGetWidth img  :: Cairo.Render Double
    h <- liftM fromIntegral $ Cairo.imageSurfaceGetHeight img :: Cairo.Render Double
    Cairo.save >> Cairo.rectangle xcd ycd (min 48 w) (min 48 h) >> Cairo.clip
    Cairo.setSourceSurface img xcd ycd
    Cairo.paint >> Cairo.restore
    return $ Cairo.RectangleInt xc yc 48 48

-- | Renders a plain rectangle /(x, y, width, height)/ in the given color.
renderEmptyRect :: Double -> Double -> Double -> Double -> CairoColor -> Cairo.Render ()
renderEmptyRect x y w h (r, g, b, a) = do
    Cairo.rectangle x y w h
    Cairo.setSourceRGBA r g b a
    Cairo.fill

-- | Creates a new unicolored drawing surface.
createEmptySurface :: Int           -- ^ width
                   -> Int           -- ^ height
                   -> CairoColor    -- ^ base color
                   -> IO Cairo.Surface
createEmptySurface w h clr = do
    sfc <- Cairo.createImageSurface Cairo.FormatARGB32 w h
    Cairo.renderWith sfc (renderEmptyRect 0 0 (fromIntegral w) (fromIntegral h) clr)
    return sfc

-- | Creates a new surface that contains the PNG image loaded from the given path.
--   Returns the loaded image in a 'Right' container on success and
--   an empty dummy image in a 'Left' container otherwise.
tryLoadPNG :: FilePath -> IO (Either Cairo.Surface Cairo.Surface)
tryLoadPNG path = do
    sfc <- Cairo.imageSurfaceCreateFromPNG path
    status <- Cairo.surfaceStatus sfc
    if (status == Cairo.StatusSuccess)
        then (return . Right) sfc
        else createEmptySurface 48 48 (0.0, 1.0, 1.0, 1.0) >>= return . Left

-- | Draws the given scenario onto the given surface object using the given raw images.
drawScenario :: Scenario sc => ImagePool -> Cairo.Surface -> ScenarioState sc -> IO ()
drawScenario imgs target scs = Cairo.renderWith target (scenarioRender imgs scs)

-- | Loads the PNG images to represent level features and player.
--
-- ====See also
-- @'tryLoadPNG'@
loadImagePool :: FilePath -- ^ root directory of all images
              -> IO ImagePool
loadImagePool parent = do
    -- find image for each existing feature
    (!ftMap, !pMap) <- foldM readFeatureImage (M.empty, M.empty) [minBound..maxBound]
    -- load raw player image
    pImg <- getPlayerImage
    return $ ImagePool ftMap pMap pImg
  where -- | Tries to find Feature image (<parent_path>/<feature>.png) and
        --   Feature image with player (<parent_path>/<feature>_Player.png), adds them to map if possible
        readFeatureImage :: (M.Map Feature Cairo.Surface, M.Map Feature Cairo.Surface)    -- ^ (Feature map, Feature+Player map)
                         -> Feature                                                       -- ^ Feature to search image for
                         -> IO (M.Map Feature Cairo.Surface, M.Map Feature Cairo.Surface)
        readFeatureImage (mFeature, mPlayer) ft = do
            let pathFeature = (parent ++ pathSeparator:(show ft) ++ ".png")
                pathWithPlayer =  (parent ++ pathSeparator:(show ft) ++ "_Player.png")
            -- search for feature image
            exist <- doesFileExist pathFeature
            mFeature' <- if exist
                        then tryLoadPNG pathFeature >>= either (\i -> putStrLn ("invalid PNG file: " ++ pathFeature) >> return i) (return)
                                 >>= return . (flip . M.insert) ft mFeature
                        else putStrLn ("missing resource file: " ++ pathFeature) >> return mFeature
            -- search for image that combines feature and player
            existP <- doesFileExist pathWithPlayer
            mPlayer' <- if existP
                         then tryLoadPNG pathWithPlayer >>= either (\i -> putStrLn ("invalid PNG file: " ++ pathWithPlayer) >> return i) (return)
                                 >>= return . (flip . M.insert) ft mPlayer
                         else return mPlayer   -- no special player-feature image exists for this feature
            return (mFeature', mPlayer')
        -- | Tries to load the player image (<parent_path>/Player.png) and uses a fallback image on failure.
        getPlayerImage :: IO Cairo.Surface
        getPlayerImage = do
            let playerPath = parent ++ pathSeparator:"Player.png"
            exist <- doesFileExist playerPath
            if exist
              then tryLoadPNG playerPath >>= either (\i -> putStrLn ("invalid PNG file: " ++ playerPath) >> return i) (return)
              else do putStrLn ("missing resource file: " ++ playerPath)
                      -- dummy fallback image
                      sfc <- Cairo.createImageSurface Cairo.FormatARGB32 48 48
                      Cairo.renderWith sfc (renderEmptyRect 0 0 48 48 (1.0, 0.0, 1.0, 1.0) >>
                                            Cairo.setSourceRGBA 0.0 1.0 0.0 1.0 >>
                                            Cairo.setLineWidth 7.0 >>
                                            Cairo.moveTo 9 9 >>
                                            Cairo.lineTo 38 38 >>
                                            Cairo.moveTo 9 38 >>
                                            Cairo.lineTo 38 9 >>
                                            Cairo.stroke
                                            )
                      return sfc


-- | Draws the @Surface@ stored in the @MVar@ within the @Render@.
--   This function can be used for buffering where the stored surface is the buffer.
copyScenarioToSurface :: MVar Cairo.Surface -> Cairo.Render ()
copyScenarioToSurface mapSurfaceRef = do
    mapSurface <- liftIO $ readMVar mapSurfaceRef
    Cairo.setSourceSurface mapSurface 0 0
    Cairo.paint

-- | Creates a @CanvasUpdateListener@ for the given @DrawingArea@ drawing the given level as initial scenario
--   using raw feature images provided by the @ImagePool@.
createCanvasViewLink :: Scenario sc => ImagePool -> DrawingArea -> ScenarioState sc -> IO (CanvasUpdateListener sc)
createCanvasViewLink imgs drawin scs = do
    let sc = scenario scs
        ((lx,ly), (hx, hy)) = getScenarioBounds sc
        xSpan = (hx-lx + 1) * 48
        ySpan = (hy-ly + 1) * 48
    scenSurface <- Cairo.createImageSurface Cairo.FormatARGB32 xSpan ySpan
    scenRef <- newMVar scenSurface
    widgetSetSizeRequest drawin xSpan ySpan
    -- draw scenario buffer image on drawing routine
    _ <- drawin `on` draw $ copyScenarioToSurface scenRef
    return $ CanvasUpdateListener imgs drawin scenRef (lx, ly)


{-
Keyboard Listener
-}

-- | 'UpdateListener' to update a statusbar with the amount of player moves.
data StatusBarListener sc = StatusBarListener Statusbar ContextId

instance Scenario sc => UpdateListener (StatusBarListener sc) IO sc where
  notifyUpdate :: (StatusBarListener sc) -> ScenarioUpdate -> ReaderT (ScenarioState sc) IO (StatusBarListener sc)
  notifyUpdate l@(StatusBarListener bar cId) u = do
      let (steps, steps') = updatedSteps u
      lift $ postGUIAsync (statusbarPush bar cId (show steps ++ " / " ++ show steps') >> return ())
      return l
  notifyNew :: (StatusBarListener sc) -> ReaderT (ScenarioState sc) IO (StatusBarListener sc)
  notifyNew l@(StatusBarListener bar cId) = do
      scs <- ask
      let (steps, steps') = spentSteps scs
      lift $ postGUIAsync (statusbarPush bar cId (show steps ++ " / " ++ show steps') >> return ())
      return l
  notifyWin :: (StatusBarListener sc) -> ReaderT (ScenarioState sc) IO (StatusBarListener sc)
  notifyWin l@(StatusBarListener bar cId) = do
      scs <- ask
      let (steps, steps') = spentSteps scs
      lift $ postGUIAsync (statusbarPush bar cId ("Victory! " ++ show steps ++ " / " ++ show steps') >> return ())
      return l

-- | Creates a @StatusBarListener@ for the given statusbar.
createStatusBarLink :: Scenario sc => Statusbar -> IO (StatusBarListener sc)
createStatusBarLink bar = do
    contextId <- statusbarGetContextId bar "Steps"
    return $ StatusBarListener bar contextId

{-
Next level switcher
Automatically switch to next level on win event
-}


-- | @UpdateListener@ to automatically advance to the next level when a scenario is won (after some time).
data LevelProgressor sc ctrl = LevelProgressor (MVar (GameSettings sc, ctrl))

instance (Scenario sc, ScenarioController ctrl sc IO) => UpdateListener (LevelProgressor sc ctrl) IO sc where
  notifyUpdate l _ = return l
  notifyNew l = return l
  notifyWin l@(LevelProgressor gRef) = lift $ do
     -- create new thread because sRef and uRef are blocked by keyboard listener
     -- additionally, changing ctrl while being called by it would not be wise, either
     _ <- forkIO (do
        var@(GameSettings scenSettings uic _, ctrl) <- takeMVar gRef
        -- test if current scenario is not last scenario AND scenario is still in winning state (may have changed after fork)
        if ((not . isLastScenarioFromPoolCurrent) scenSettings && (isWinningState . getControllerScenarioState) ctrl) 
          then do  -- initiate level progression
            putStrLn "shortly progressing to next level"
            me <- myThreadId
            -- disable player movement and register stalled change, leave controller unchanged
            putMVar gRef (var & _1 %~ (lensStalledScenarioChange .~ ChangeStalled me (currentScenario scenSettings + 1))
                                    . (lensUserInputControl . lensMovementMode .~ MovementDisabled))

            -- wait some time with level change
            threadDelay 2000000    -- microseconds
            var@(gSett@(GameSettings scenSettings uic stalled), ctrl) <- takeMVar gRef
            -- test if thread id is still registered, otherwise: do nothing
            -- (level may have been changed manually, reset, undone, ...)
            if maybe (False) (== me) (stalled ^? lensStallingThreadId)
              then do
                 -- set next level
                                                                  -- is guaranteed to be Just ... because of earlier check
                 let mbNextScen = setCurrentScenario scenSettings (fromJust $ stalled ^? lensStalledScenarioId)
                 maybe (do putMVar gRef (var & _1 . lensStalledScenarioChange .~ NoChangeStalled))  -- no "next" scenario, do "nothing"
                       (\(scenSettings', newScen) -> do
                           (_, ctrl') <- runStateT (setScenario newScen) ctrl
                           putMVar gRef (gSett & (lensUserInputControl . lensMovementMode .~ MovementEnabled)  -- enable user movement
                                               . (lensScenarioSettings .~ scenSettings')                       -- update ScenarioSettings
                                               . (lensStalledScenarioChange .~ NoChangeStalled)                -- remove possibly stalled change
                                               , ctrl'))                                                       -- update controller
                       mbNextScen
              else do  -- some other thread grabbed "lock" to change scenario
                 putMVar gRef var
          else do  -- is last scenario OR state is not winning any longer (for whatever reasons)
             uic' <- if (isWinningState . getControllerScenarioState) ctrl
                       -- last scenario reached, disable movement
                       then putStrLn "Dark Victory!!!!" >> return (uic & lensMovementMode .~ MovementDisabled)
                       -- whatever, do nothing
                       else return uic
             putMVar gRef (var & _1 . lensUserInputControl .~ uic')
       )
     return l

-- | Creates a @LevelProgressor@ using the given settings and game controller.
createLevelProgressor :: (Scenario sc, ScenarioController ctrl sc IO) => MVar (GameSettings sc, ctrl) -> LevelProgressor sc ctrl
createLevelProgressor = LevelProgressor

{-
Level id updater
-}

-- | Do something on 'notifyNew'. @storage@ may be a constant value or an 'MVar' or the like.
data LevelNewListener sc storage m = LevelNewListener (storage -> ScenarioState sc -> m ()) storage

instance (Monad m, Scenario sc) => UpdateListener (LevelNewListener sc ctrl m) m sc where
  notifyUpdate l _ = return l
  notifyNew l@(LevelNewListener action storage) = do
      scState <- ask
      lift $ action storage scState 
      return l
  notifyWin l = return l


{-
Other stuff
-}

-- | Advances the game to the next scenario. Returns @IO 'Nothing'@ if there is no next scenario to choose.
setNextScenarioLevel :: (ScenarioController ctrl sc IO) => (GameSettings sc, ctrl) -> IO (Maybe (GameSettings sc, ctrl))
setNextScenarioLevel (g@(GameSettings scenSettings _ _), ctrl) =
    case increaseScenarioId scenSettings of
         Just (scenSettings', nextScen, _) -> do
             (_, ctrl') <- runStateT (setScenario nextScen) ctrl
             -- there may be a delayed level change -> enable player movement
             return $ Just (g & (lensUserInputControl . lensMovementMode .~ MovementEnabled)
                              . (lensScenarioSettings .~ scenSettings')
                              . (lensStalledScenarioChange .~ NoChangeStalled)
                              , ctrl')
         Nothing -> return Nothing

-- | Proceed the game with the previous scenario. Returns @IO 'Nothing'@ if there is no previous scenario to choose.
setPrevScenarioLevel :: (ScenarioController ctrl sc IO) => (GameSettings sc, ctrl) -> IO (Maybe (GameSettings sc, ctrl))
setPrevScenarioLevel (g@(GameSettings scenSettings _ _), ctrl) =
    case decreaseScenarioId scenSettings of
         Just (scenSettings', nextScen, _) -> do
             (_, ctrl') <- runStateT (setScenario nextScen) ctrl
             -- there may be a delayed level change -> enable player movement
             return $ Just (g & (lensUserInputControl . lensMovementMode .~ MovementEnabled)
                              . (lensScenarioSettings .~ scenSettings')
                              . (lensStalledScenarioChange .~ NoChangeStalled)
                              , ctrl')
         Nothing -> return Nothing

-- | Resets the current scenario of the game to its initial state.
resetCurrentScenarioLevel :: (ScenarioController ctrl sc IO) => (GameSettings sc, ctrl) -> IO (GameSettings sc, ctrl)
resetCurrentScenarioLevel (g@(GameSettings scenSettings _ _), ctrl) = do
    let currentScen = getScenarioFromPool scenSettings (currentScenario scenSettings)
    (_, ctrl') <- runStateT (setScenario currentScen) ctrl
    -- there may be a delayed level change -> enable player movement
    return (g & (lensUserInputControl . lensMovementMode .~ MovementEnabled)
              . (lensStalledScenarioChange .~ NoChangeStalled)
              , ctrl')



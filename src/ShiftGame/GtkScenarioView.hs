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
import ShiftGame.Helpers
import ShiftGame.Scenario
import ShiftGame.ScenarioController

-- MVar order: get (Scenario sc, ScenarioController ctrl m sc) => (MVar (ScenarioSettings sc, ctrl)) before (MVar UserInputControl) within a thread

data MovementMode = MovementEnabled | MovementDisabled deriving (Bounded, Eq, Show, Read, Enum)

-- | When a scenario change is scheduled, stores the thread id of the stalling thread.
--   The thread should only execute the scheduled switch if the thread id remains the same when the change is due.
data ScenarioChangeMode = NoChangeStalled | ChangeStalled { stallingThreadId :: ThreadId, stalledScenarioId :: ScenarioId } deriving (Eq, Show)
$(makeLensPrefixLenses ''ScenarioChangeMode)
$(makePrisms ''ScenarioChangeMode)


data InputMode = InputMode { movementMode :: MovementMode
                           , scenarioChangeMode :: ScenarioChangeMode
                           } deriving (Eq, Show)
$(makeLensPrefixLenses ''InputMode)

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
                                         , inputMode :: InputMode -- ^ what user interactions are currently possible
                                         } deriving (Eq, Show)
$(makeLensPrefixLenses ''UserInputControl)

{-
TextView based view
-}

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
  notifyWin l@(TextViewUpdateListener tBuffer) = return l

createTextViewLink :: TextBuffer -> TextViewUpdateListener
createTextViewLink tBuffer = TextViewUpdateListener tBuffer


{-
Graphics View
-}

data ImagePool = ImagePool { featureMap :: M.Map Feature Cairo.Surface -- ^ map containing images for raw features
                           , playerMap  :: M.Map Feature Cairo.Surface -- ^ map containing images for player onto feature, if special
                           , playerImg  :: Cairo.Surface               -- ^ player image to draw onto feature if not contained in playerMap
                           }
$(makeLensPrefixLenses ''ImagePool)

data CanvasUpdateListener = CanvasUpdateListener { bufferedImages :: ImagePool            -- ^ Available images to draw onto canvas
                                                 , drawCanvas     :: DrawingArea          -- ^ Connected @DrawingArea@ serving as canvas
                                                 , surfaceRef     :: MVar Cairo.Surface  -- ^ Reference to Cairo image of currently drawed scenario
                                                 , lowScenarioBnd :: (Int, Int)           -- ^ Lower (x, y) bounds of current scenario
                                                 }
$(makeLensPrefixLenses ''CanvasUpdateListener)

instance UpdateListener CanvasUpdateListener IO MatrixScenario where
  notifyUpdate :: CanvasUpdateListener -> ScenarioUpdate -> ReaderT (ScenarioState MatrixScenario) IO CanvasUpdateListener
  notifyUpdate l@(CanvasUpdateListener imgs widget sfcRef lowBnd) u = do
      sfc <- lift $ readMVar sfcRef
      invalRegion <- lift $ Cairo.renderWith sfc (scenarioUpdateRender imgs u lowBnd)
      lift $ postGUIAsync (widgetQueueDrawRegion widget invalRegion)
      return l
  notifyNew :: CanvasUpdateListener -> ReaderT (ScenarioState MatrixScenario) IO CanvasUpdateListener
  notifyNew l@(CanvasUpdateListener imgs widget sfcRef _) = do
      scs <- ask
      let ((lx,ly), (hx, hy)) = getMatrixScenarioBounds (scenario scs)
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
          when (w /= xSpan || h /= ySpan) (widgetSetSizeRequest widget xSpan ySpan)
          -- redraw scenario surface
          drawScenario imgs nextSfc scs
          widgetQueueDraw widget)
      return $ set lensLowScenarioBnd (lx,ly) l
  notifyWin :: CanvasUpdateListener -> ReaderT (ScenarioState MatrixScenario) IO CanvasUpdateListener
  notifyWin l = return l

scenarioRender :: ImagePool -> ScenarioState MatrixScenario -> Cairo.Render ()
scenarioRender imgs scs = do
    -- paint magent rectangle for invalid textures
    (cx1, cy1, cx2, cy2) <- Cairo.clipExtents
    Cairo.rectangle cx1 cy1 cx2 cy2
    Cairo.setSourceRGB 1.0 0.0 1.0
    Cairo.fill
    -- paint scenario map
    let (l@(lx,ly), (hx, hy)) = getMatrixScenarioBounds (scenario scs)
    sequence_ $ map (drawFeature l) [(x, y) | x <- [lx..hx], y <- [ly..hy]]
    -- paint player
    drawPlayer l (playerCoord scs)
  where drawFeature :: (Int, Int) -> (Int, Int) -> Cairo.Render ()
        drawFeature (lx, ly) c@(x, y) = case M.lookup (fromMaybe Wall $ getFeature (scenario scs) c) (featureMap imgs) of
            Just sfc -> let xc = (fromIntegral (x - lx)) * 48
                            yc = (fromIntegral (y - ly)) * 48
                        in do w <- liftM fromIntegral $ Cairo.imageSurfaceGetWidth sfc  :: Cairo.Render Double
                              h <- liftM fromIntegral $ Cairo.imageSurfaceGetHeight sfc :: Cairo.Render Double
                              Cairo.save >> Cairo.rectangle xc yc (min 48 w) (min 48 h) >> Cairo.clip
                              Cairo.setSourceSurface sfc xc yc >> Cairo.paint >> Cairo.restore
            Nothing -> return ()
        drawPlayer :: (Int, Int) -> (Int, Int) -> Cairo.Render ()
        drawPlayer (lx, ly) c@(x, y) =
            let xc = (fromIntegral (x - lx)) * 48
                yc = (fromIntegral (y - ly)) * 48
            in do img <- case M.lookup (fromMaybe Wall $ getFeature (scenario scs) c) (playerMap imgs) of
                              Just sfc -> return sfc
                              Nothing -> return (playerImg imgs)
                  w <- liftM fromIntegral $ Cairo.imageSurfaceGetWidth img  :: Cairo.Render Double
                  h <- liftM fromIntegral $ Cairo.imageSurfaceGetHeight img :: Cairo.Render Double
                  Cairo.save >> Cairo.rectangle xc yc (min 48 w) (min 48 h) >> Cairo.clip
                  Cairo.setSourceSurface img xc yc >> Cairo.paint >> Cairo.restore  
                              

scenarioUpdateRender :: ImagePool                    -- ^ single sprites
                     -> ScenarioUpdate               -- ^ new scenario state
                     -> (Int, Int)                   -- ^ lower (x, y) scenario bounds
                     -> Cairo.Render (Cairo.Region)
scenarioUpdateRender imgs u (lx, ly) = do
    -- overpaint given coordinates
    let pc = newPlayerCoord u
        -- find current player position in update list
        (pCoord, pNotCoord) = partition (\(c, _) -> c == pc) (changedFeatures u)
    inval  <- sequence $ map drawFeature pNotCoord
    inval' <- sequence $ map drawPlayer pCoord
    Cairo.regionCreateRectangles (inval ++ inval')
  where drawFeature :: (Coord, Feature) -> Cairo.Render Cairo.RectangleInt
        drawFeature ((x, y), ft) = do
            let xc = (x - lx) * 48
                yc = (y - ly) * 48
                xcd = fromIntegral xc :: Double
                ycd = fromIntegral yc :: Double
            case M.lookup ft (featureMap imgs) of
                 Just sfc -> do w <- liftM fromIntegral $ Cairo.imageSurfaceGetWidth sfc  :: Cairo.Render Double
                                h <- liftM fromIntegral $ Cairo.imageSurfaceGetHeight sfc :: Cairo.Render Double
                                Cairo.save >> Cairo.rectangle xcd ycd (min 48 w) (min 48 h) >> Cairo.clip
                                Cairo.setSourceSurface sfc xcd ycd >> Cairo.paint >> Cairo.restore
                 Nothing -> renderEmptyRect xcd ycd 48 48 (1.0, 0.0, 1.0, 1.0)
            return $ Cairo.RectangleInt xc yc 48 48
        drawPlayer :: (Coord, Feature) -> Cairo.Render Cairo.RectangleInt
        drawPlayer item@((x, y), ft) = do
            let xc = (x - lx) * 48
                yc = (y - ly) * 48
                xcd = fromIntegral xc
                ycd = fromIntegral yc
            img <- case M.lookup ft (playerMap imgs) of
                        -- draw combined "Feature+Player" image, if available
                        Just sfc -> return sfc
                        -- draw raw feature and paint player image on top
                        Nothing -> drawFeature item >> return (playerImg imgs)
            w <- liftM fromIntegral $ Cairo.imageSurfaceGetWidth img  :: Cairo.Render Double
            h <- liftM fromIntegral $ Cairo.imageSurfaceGetHeight img :: Cairo.Render Double
            Cairo.save >> Cairo.rectangle xcd ycd (min 48 w) (min 48 h) >> Cairo.clip
            Cairo.setSourceSurface img xcd ycd
            Cairo.paint >> Cairo.restore
            return $ Cairo.RectangleInt xc yc 48 48
            
-- | RGBA color components.
type CairoColor = (Double, Double, Double, Double)

renderEmptyRect :: Double -> Double -> Double -> Double -> CairoColor -> Cairo.Render ()
renderEmptyRect x y w h (r, g, b, a) = do
    Cairo.rectangle x y w h
    Cairo.setSourceRGBA r g b a
    Cairo.fill

createEmptySurface :: Int -> Int -> CairoColor -> IO Cairo.Surface
createEmptySurface w h clr = do
    sfc <- Cairo.createImageSurface Cairo.FormatARGB32 w h
    Cairo.renderWith sfc (renderEmptyRect 0 0 (fromIntegral w) (fromIntegral h) clr)
    return sfc

tryLoadPNG :: FilePath -> IO Cairo.Surface
tryLoadPNG path = do
    sfc <- Cairo.imageSurfaceCreateFromPNG path
    status <- Cairo.surfaceStatus sfc
    if (status == Cairo.StatusSuccess)
        then return sfc
        else putStrLn ("invalid PNG file: " ++ path)
          >> createEmptySurface 48 48 (0.0, 1.0, 1.0, 1.0)

drawScenario :: ImagePool -> Cairo.Surface -> ScenarioState MatrixScenario -> IO ()
drawScenario imgs target scs = Cairo.renderWith target (scenarioRender imgs scs)


loadImagePool :: FilePath -> IO ImagePool
loadImagePool parent = do
    (!ftMap, !pMap) <- foldM readFeatureImage (M.empty, M.empty) [minBound..maxBound]
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
            exist <- doesFileExist pathFeature
            mFeature' <- if exist
                        then tryLoadPNG pathFeature >>= return . (flip . M.insert) ft mFeature
                        else putStrLn ("missing resource file: " ++ pathFeature) >> return mFeature
            existP <- doesFileExist pathWithPlayer
            mPlayer' <- if existP
                         then tryLoadPNG pathWithPlayer >>= return . (flip . M.insert) ft mPlayer
                         else return mPlayer
            return (mFeature', mPlayer')
        getPlayerImage :: IO Cairo.Surface
        getPlayerImage = do
            let playerPath = parent ++ pathSeparator:"Player.png"
            exist <- doesFileExist playerPath
            if exist
              then tryLoadPNG playerPath
              else do putStrLn ("missing resource file: " ++ playerPath)
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


copyScenarioToSurface :: MVar Cairo.Surface -> Cairo.Render ()
copyScenarioToSurface mapSurfaceRef = do
    mapSurface <- liftIO $ readMVar mapSurfaceRef
    Cairo.setSourceSurface mapSurface 0 0
    Cairo.paint


createCanvasViewLink :: ImagePool -> DrawingArea -> ScenarioState MatrixScenario -> IO CanvasUpdateListener
createCanvasViewLink imgs drawin scs = do
    let sc = scenario scs
        ((lx,ly), (hx, hy)) = getMatrixScenarioBounds sc
        xSpan = (hx-lx + 1) * 48
        ySpan = (hy-ly + 1) * 48
    scenSurface <- Cairo.createImageSurface Cairo.FormatARGB32 xSpan ySpan
    scenRef <- newMVar scenSurface
    widgetSetSizeRequest drawin xSpan ySpan
    _ <- drawin `on` draw $ copyScenarioToSurface scenRef
    return $ CanvasUpdateListener imgs drawin scenRef (lx, ly)


{-
Keyboard Listener
-}

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

createStatusBarLink :: Scenario sc => Statusbar -> IO (StatusBarListener sc)
createStatusBarLink bar = do
    contextId <- statusbarGetContextId bar "Steps"
    return $ StatusBarListener bar contextId

{-
Next level switcher
Automatically switch to next level on win event
-}


-- | @UpdateListener@ to automatically advance to the next level when a scenario is won (after some time).
--   
--   @MVar (ScenarioSettings sc, ctrl)@ is always acquired before @MVar UserInputControl@
data LevelProgressor sc ctrl = LevelProgressor (MVar UserInputControl) (MVar (ScenarioSettings sc, ctrl))


instance (Scenario sc, ScenarioController ctrl sc IO) => UpdateListener (LevelProgressor sc ctrl) IO sc where
  notifyUpdate l _ = return l
  notifyNew l = return l
  notifyWin l@(LevelProgressor uRef sRef) = lift $ do
     -- create new thread because sRef and uRef are blocked by keyboard listener
     _ <- forkIO (do
        var@(scenSettings, ctrl) <- takeMVar sRef
        uic <- takeMVar uRef
        -- test if current scenario is not last scenario AND scenario is still in winning state (may have changed after fork)
        if ((not . isLastScenarioFromPoolCurrent) scenSettings && (isWinningState . getControllerScenarioState) ctrl) 
          then do  -- initiate level progression
            putStrLn "shortly progressing to next level"
            me <- myThreadId
            -- disable player movement and register stalled change
            putMVar uRef (uic & lensInputMode %~ (lensScenarioChangeMode .~ ChangeStalled me (currentScenario scenSettings + 1))
                                               . (lensMovementMode .~ MovementDisabled))
            putMVar sRef var
            -- wait some time with level change
            threadDelay 2000000    -- microseconds
            var@(scenSettings, ctrl) <- takeMVar sRef
            uic <- takeMVar uRef
            -- test if thread id is still registered, otherwise: do nothing
            -- (level may have been changed manually, reset, undone, ...)
            if maybe (False) (== me) (uic ^? lensInputMode . lensScenarioChangeMode . lensStallingThreadId)
              then do
                 -- set next level
                                                                  -- is guaranteed to be Just ... because of earlier check
                 let mbNextScen = setCurrentScenario scenSettings (fromJust $ uic ^? lensInputMode . lensScenarioChangeMode . lensStalledScenarioId)
                 maybe (do putMVar uRef (uic & lensInputMode . lensScenarioChangeMode .~ NoChangeStalled)
                           putMVar sRef var)                         -- no "next" scenario, do nothing
                       (\(scenSettings', newScen) -> do
                           (_, ctrl') <- runStateT (setScenario newScen) ctrl
                           putMVar uRef (uic & lensInputMode %~ (lensMovementMode .~ MovementEnabled)
                                                              . (lensScenarioChangeMode .~ NoChangeStalled))
                           putMVar sRef (scenSettings', ctrl'))      -- change scenario
                       mbNextScen
              else do
                 putMVar uRef uic
                 putMVar sRef var
          else do  -- is last scenario OR state is not winning any longer (for whatever reasons)
             if (isWinningState . getControllerScenarioState) ctrl
               -- last scenario reached, disable movement
               then putMVar uRef (uic & lensInputMode . lensMovementMode .~ MovementDisabled)
                 >> putStrLn "Dark Victory!!!!"
               -- whatever, do nothing
               else putMVar uRef uic
             putMVar sRef var
       )
     return l


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

setNextScenarioLevel :: (ScenarioController ctrl MatrixScenario IO) => UserInputControl -> (ScenarioSettings MatrixScenario, ctrl) -> IO (Maybe (UserInputControl, (ScenarioSettings MatrixScenario, ctrl)))
setNextScenarioLevel uic (scenSettings, ctrl) =
    case increaseScenarioId scenSettings of
         Just (scenSettings', nextScen, _) -> do
             (_, ctrl') <- runStateT (setScenario nextScen) ctrl
             -- there may be a delayed level change -> enable player movement
             return $ Just (uic & lensInputMode %~ (lensMovementMode .~ MovementEnabled) . (lensScenarioChangeMode .~ NoChangeStalled), (scenSettings', ctrl'))
         Nothing -> return Nothing

setPrevScenarioLevel :: (ScenarioController ctrl MatrixScenario IO) => UserInputControl -> (ScenarioSettings MatrixScenario, ctrl) -> IO (Maybe (UserInputControl, (ScenarioSettings MatrixScenario, ctrl)))
setPrevScenarioLevel uic (scenSettings, ctrl) =
    case decreaseScenarioId scenSettings of
         Just (scenSettings', nextScen, _) -> do
             (_, ctrl') <- runStateT (setScenario nextScen) ctrl
             -- there may be a delayed level change -> enable player movement
             return $ Just (uic & lensInputMode %~ (lensMovementMode .~ MovementEnabled) . (lensScenarioChangeMode .~ NoChangeStalled), (scenSettings', ctrl'))
         Nothing -> return Nothing

resetCurrentScenarioLevel :: (ScenarioController ctrl MatrixScenario IO) => UserInputControl -> (ScenarioSettings MatrixScenario, ctrl) -> IO (UserInputControl, (ScenarioSettings MatrixScenario, ctrl))
resetCurrentScenarioLevel uic (scenSettings, ctrl) = do
    let currentScen = getScenarioFromPool scenSettings (currentScenario scenSettings)
    (_, ctrl') <- runStateT (setScenario currentScen) ctrl
    -- there may be a delayed level change -> enable player movement
    return (uic & lensInputMode %~ (lensMovementMode .~ MovementEnabled) . (lensScenarioChangeMode .~ NoChangeStalled), (scenSettings, ctrl'))

-- | Destroys all given windows and clears the @MVar@.
quitAllWindows :: MVar [Window] -> IO ()
quitAllWindows wRef = do
    windows <- takeMVar wRef
    mapM_ widgetDestroy windows
    putMVar wRef []




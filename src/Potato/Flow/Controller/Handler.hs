{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}

module Potato.Flow.Controller.Handler (

  handlerName_box
  , handlerName_simpleLine
  , handlerName_cartesianLine
  , handlerName_boxText
  , handlerName_pan
  , handlerName_select
  , handlerName_empty

  , PotatoHandlerOutput(..)
  , PotatoHandler(..)
  , PotatoHandlerInput(..)
  , HandlerRenderOutput(..)
  , emptyHandlerRenderOutput
  , SomePotatoHandler(..)
  , captureWithNoChange
  , setHandlerOnly
  , EmptyHandler(..)
) where

import           Relude

import           Potato.Flow.BroadPhase
import           Potato.Flow.Controller.Input
import           Potato.Flow.Controller.Layers
import           Potato.Flow.Controller.Types
import           Potato.Flow.Math
import           Potato.Flow.SElts
import           Potato.Flow.State
import           Potato.Flow.Types
import           Potato.Flow.Workspace

import           Data.Default
import           Data.Dependent.Sum            (DSum ((:=>)))
import qualified Data.IntMap                   as IM
import qualified Data.List                     as L
import qualified Data.Sequence                 as Seq
import qualified Data.Text                     as T
import           Data.Tuple.Extra
import qualified Text.Show

data PotatoHandlerOutput = PotatoHandlerOutput {
    _potatoHandlerOutput_nextHandler   :: Maybe SomePotatoHandler
    , _potatoHandlerOutput_select      :: Maybe (Bool, Selection)
    , _potatoHandlerOutput_pFEvent     :: Maybe WSEvent
    , _potatoHandlerOutput_pan         :: Maybe XY
    , _potatoHandlerOutput_layersState :: Maybe LayersState
  } deriving (Show)

instance Default PotatoHandlerOutput where
  def = PotatoHandlerOutput {
      _potatoHandlerOutput_nextHandler = Nothing
      , _potatoHandlerOutput_pFEvent = Nothing
      , _potatoHandlerOutput_pan = Nothing
      , _potatoHandlerOutput_select = Nothing
      , _potatoHandlerOutput_layersState = Nothing
    }

-- TODO replace this with just GoatState
data PotatoHandlerInput = PotatoHandlerInput {
    -- * from PFOutput
    _potatoHandlerInput_pFState       :: PFState
    , _potatoHandlerInput_broadPhase  :: BroadPhaseState
    , _potatoHandlerInput_layerPosMap :: LayerPosMap

    -- * from Frontend
    , _potatoHandlerInput_tool        :: Tool
    , _potatoHandlerInput_layersState :: LayersState

    -- * from Backend
    -- basically, handlers are created based on contents of selection, and handlers themselves are expected to use partial methods on selection to get relevant information in order to modify the selection
    -- note that selection is dynamically updated each type a change is made so it always has up to date information during a multi-step manipulate
    -- this is sort of just how it is right now, I wish it weren't so :_(
    , _potatoHandlerInput_selection   :: Selection
  }

data HandlerRenderOutput = HandlerRenderOutput {
    _handlerRenderOutput_temp :: [LBox] -- list of coordinates where there are handles
  } deriving (Eq)

instance Default HandlerRenderOutput where
  def = emptyHandlerRenderOutput

emptyHandlerRenderOutput :: HandlerRenderOutput
emptyHandlerRenderOutput = HandlerRenderOutput { _handlerRenderOutput_temp = [] }

-- we check handler name for debug reasons so it's useful to have constants
-- there should be no non-test code that depends on comparing pHandlerName
handlerName_box :: Text
handlerName_box = "BoxHandler"
handlerName_simpleLine :: Text
handlerName_simpleLine = "SimpleLineHandler"
handlerName_cartesianLine :: Text
handlerName_cartesianLine = "CartesianLineHandler"
handlerName_boxText :: Text
handlerName_boxText = "BoxTextHandler"
handlerName_pan :: Text
handlerName_pan = "PanHandler"
handlerName_select :: Text
handlerName_select = "SelectHandler"
handlerName_empty :: Text
handlerName_empty = "EmptyHandler"


-- TODO prob replace this with 'data PotatoHandler' rather than typeclass
-- TODO rename methods in here..
-- rename to Manipulator XD
class PotatoHandler h where
  pHandlerName :: h -> Text

  -- TODO do the generic thing where (Show h) whatever (I guess this only works when you use deriving or something though?)
  pHandlerDebugShow :: h -> Text
  pHandlerDebugShow _ = "<no debug info>"

  -- TODO consider removing Selection from input args since it should be static through lifetime of handler and therefore passed in during construction
  -- i.e. invariant is selection changed -> new handler

  -- TODO need to add broadphase to args as it's used for finding new selections..
  -- TODO maybe split into handleLayerMouse (MouseDrag) and handleCanvasMouse (RelMosueDrag)?
  -- NOTE, MouseDragState_Cancelled will never be passed into this
  -- return type of Nothing means input is not captured
  pHandleMouse :: h -> PotatoHandlerInput -> RelMouseDrag -> Maybe PotatoHandlerOutput

  -- return type of Nothing means input is not captured
  pHandleKeyboard :: h -> PotatoHandlerInput -> KeyboardData -> Maybe PotatoHandlerOutput

  -- reset handler if an event came in in between
  -- FOR NOW we expect this to only be called if handler is not active
  -- FOR NOW this is only allowed to return the existing handler
  -- when we have multi-user, this may return actions, and may happen when a handler is active
  pResetHandler :: h -> PotatoHandlerInput -> Maybe SomePotatoHandler
  -- prob not correct behavior, if you delete an elt (say), then you don't want to persist the handler
  --pResetHandler h _ = Just $ SomePotatoHandler h
  pResetHandler h _ = Nothing

  -- active manipulators will not be overwritten by new handlers via selection from backend
  pIsHandlerActive :: h -> Bool
  pIsHandlerActive _ = False

  pRenderHandler :: h -> PotatoHandlerInput -> HandlerRenderOutput
  pRenderHandler _ _ = def

  -- helper method used to check that we aren't feeding invalid mouse states
  pValidateMouse :: h -> RelMouseDrag -> Bool
  -- default version that ensures mouse state is valid when handler is active
  pValidateMouse h (RelMouseDrag MouseDrag {..}) = case _mouseDrag_state of
    MouseDragState_Cancelled -> False
    MouseDragState_Down      -> not $ pIsHandlerActive h
    _                        -> True


data SomePotatoHandler = forall h . PotatoHandler h  => SomePotatoHandler h

instance PotatoHandler SomePotatoHandler where
  pHandlerName (SomePotatoHandler h) = pHandlerName h
  pHandlerDebugShow (SomePotatoHandler h) = pHandlerDebugShow h
  pHandleMouse (SomePotatoHandler h) = pHandleMouse h
  pHandleKeyboard (SomePotatoHandler h) = pHandleKeyboard h
  pIsHandlerActive (SomePotatoHandler h) = pIsHandlerActive h
  pResetHandler (SomePotatoHandler h) = pResetHandler h
  pRenderHandler (SomePotatoHandler h) = pRenderHandler h
  pValidateMouse (SomePotatoHandler h) = pValidateMouse h

captureWithNoChange :: (PotatoHandler h) => h -> PotatoHandlerOutput
captureWithNoChange h = def {
    _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler h
  }

setHandlerOnly :: (PotatoHandler h) => h -> PotatoHandlerOutput
setHandlerOnly = captureWithNoChange

instance Show SomePotatoHandler where
  show (SomePotatoHandler h) = T.unpack $ "SomePotatoHandler " <> pHandlerName h <> " active: " <> show (pIsHandlerActive h)

testHandleMouse :: SomePotatoHandler -> PotatoHandlerInput -> RelMouseDrag -> Maybe PotatoHandlerOutput
testHandleMouse (SomePotatoHandler h) phi rmd = pHandleMouse h phi rmd


data EmptyHandler = EmptyHandler

instance PotatoHandler EmptyHandler where
  pHandlerName _ = "EmptyHandler"
  pHandleMouse _ _ _ = Nothing
  pHandleKeyboard _ _ _ = Nothing
  pRenderHandler _ _ = def
  pValidateMouse _ _ = True


{--
-- you can do something like the below to have handlers share some functionality
-- unfortuantely, the design below is not very composable, although maybe this isn't really something that can be composed
data ActiveHandlerState s = ActiveHandlerState {
    _activeHandlerState_isActive :: Bool
    _activeHandlerState_userState :: s
  }

data ActiveHandler s = ActiveHandler {
  _activeHandler_pHandleMouse :: s -> PotatoHandlerInput -> RelMouseDrag -> (Bool, Maybe PotatoHandlerOutput)
  -- ...
}
--}

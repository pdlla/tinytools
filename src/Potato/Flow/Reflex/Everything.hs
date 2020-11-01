{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}

-- TODO move out of Reflex folder
module Potato.Flow.Reflex.Everything (
  KeyboardData(..)
  , KeyboardKey(..)
  , KeyboardKeyType(..)

  , MouseModifier(..)
  , MouseButton(..)
  , MouseDragState(..)
  , LMouseData(..)
  , MouseDrag(..)
  , newDrag
  , continueDrag
  , cancelDrag
  , mouseDragDelta

  , FrontendOperation(..)
  , Tool(..)
  , LayerDisplay(..)

  , MouseManipulator(..)
  , MouseManipulatorSet
  , toMouseManipulators
  , findFirstMouseManipulator

  , Selection
  , disjointUnionSelection
  , EverythingFrontend(..)
  , EverythingBackend(..)
  , emptyEverythingFrontend
  , emptyEverythingBackend
  , EverythingCombined_DEBUG(..)
  , combineEverything

) where

import           Relude

import           Potato.Flow.BroadPhase
import           Potato.Flow.Math
import           Potato.Flow.Render
import           Potato.Flow.SEltMethods
import           Potato.Flow.SElts
import           Potato.Flow.State
import           Potato.Flow.Types

-- erhm, maybe move PFEventTag to somewhere else? Could just duplicate it in this file
import           Potato.Flow.Reflex.Entry (PFEventTag)

import           Control.Exception        (assert)
import           Data.Dependent.Sum       (DSum ((:=>)), (==>))
import qualified Data.IntMap              as IM
import qualified Data.List                as L
import qualified Data.Sequence            as Seq

-- KEYBOARD
-- TODO decide if text input happens here or in front end
-- (don't wanna implement my own text zipper D:)
data KeyboardData = KeyboardData KeyboardKey KeyboardKeyType

data KeyboardKey =
  KeyboardKey_Esc
  | KeyboardKey_Return
  | KeyboardKey_Space
  | KeyboardKey_Char Char
  deriving (Show, Eq)

data KeyboardKeyType =
  KeyboardKeyType_Down
  | KeyboardKeyType_Up
  | KeyboardKeyType_Click
  deriving (Show, Eq)

-- MOUSE
-- TODO move all this stuff to types folder or something
-- only ones we care about
data MouseModifier = MouseModifier_Shift | MouseModifier_Alt deriving (Show, Eq)

data MouseButton = MouseButton_Left | MouseButton_Middle | MouseButton_Right deriving (Show, Eq)

data MouseDragState = MouseDragState_Down | MouseDragState_Dragging | MouseDragState_Up | MouseDragState_Cancelled deriving (Show, Eq)

-- TODO add modifier
-- TODO is this the all encompassing mouse event we want?
-- TODO is there a way to optionally support more fidelity here?
-- mouse drags are sent as click streams
data LMouseData = LMouseData {
  _lMouseData_position    :: XY
  , _lMouseData_isRelease :: Bool
  , _lMouseData_button    :: MouseButton
  , _lMouseData_modifiers :: [MouseModifier]
} deriving (Show, Eq)

data MouseDrag = MouseDrag {
  _mouseDrag_from        :: XY -- TODO rename to mousedrag from
  , _mouseDrag_button    :: MouseButton -- tracks button on start of drag
  , _mouseDrag_modifiers :: [MouseModifier] -- tracks modifiers held at current state of drag
  , _mouseDrag_to        :: XY -- likely not needed as they will be in the input event, but whatever
  , _mouseDrag_state     :: MouseDragState
} deriving (Show, Eq)

emptyMouseDrag :: MouseDrag
emptyMouseDrag = MouseDrag {
    _mouseDrag_from  = 0
    , _mouseDrag_button = MouseButton_Left
    , _mouseDrag_modifiers = []
    , _mouseDrag_to    = 0
    , _mouseDrag_state = MouseDragState_Cancelled
  }

newDrag :: LMouseData -> MouseDrag
newDrag LMouseData {..} = assert (not _lMouseData_isRelease) $ MouseDrag {
    _mouseDrag_from = _lMouseData_position
    , _mouseDrag_button = _lMouseData_button
    , _mouseDrag_modifiers = _lMouseData_modifiers
    , _mouseDrag_to = _lMouseData_position
    , _mouseDrag_state = MouseDragState_Down
  }

continueDrag :: LMouseData -> MouseDrag -> MouseDrag
continueDrag LMouseData {..} md = md {
    _mouseDrag_to = _lMouseData_position
    , _mouseDrag_state = if _lMouseData_isRelease
      then MouseDragState_Up
      else MouseDragState_Dragging
    , _mouseDrag_modifiers = _lMouseData_modifiers
  }

cancelDrag :: MouseDrag -> MouseDrag
cancelDrag md = md { _mouseDrag_state = MouseDragState_Cancelled }

mouseDragDelta :: MouseDrag -> MouseDrag -> XY
mouseDragDelta md prev = (_mouseDrag_to md) - (_mouseDrag_to prev)


-- TOOL
data Tool = Tool_Select | Tool_Pan | Tool_Box | Tool_Line | Tool_Text deriving (Eq, Show, Enum)

-- LAYER
data LayerDisplay = LayerDisplay {
  _layerDisplay_isFolder :: Bool
  , _layerDisplay_name   :: Text
  , _layerDisplay_ident  :: Int
  -- TODO hidden/locked states
  -- TODO reverse mapping to selt
}

-- SELECTION
type Selection = Seq SuperSEltLabel

-- TODO move to its own file
-- selection helpers
disjointUnion :: (Eq a) => [a] -> [a] -> [a]
disjointUnion a b = L.union a b L.\\ L.intersect a b

-- TODO real implementation...
disjointUnionSelection :: Selection -> Selection -> Selection
disjointUnionSelection s1 s2 = Seq.fromList $ disjointUnion (toList s1) (toList s2)

data SelectionManipulatorType = SMTNone | SMTBox | SMTLine | SMTText | SMTBoundingBox deriving (Show, Eq)

computeSelectionType :: Selection -> SelectionManipulatorType
computeSelectionType = foldl' foldfn SMTNone where
  foldfn accType (_,_,SEltLabel _ selt) = case accType of
    SMTNone -> case selt of
      SEltBox _  -> SMTBox
      SEltLine _ -> SMTLine
      SEltText _ -> SMTText
      _          -> SMTNone
    _ -> SMTBoundingBox


changeSelection :: Selection -> EverythingBackend -> EverythingBackend
changeSelection newSelection everything@EverythingBackend {..} = everything {
    _everythingBackend_selection = newSelection
    , _everythingBackend_manipulators = toMouseManipulators newSelection
  }

-- MANIPULATORS
data MouseManipulatorType = MouseManipulatorType_Corner | MouseManipulatorType_Point deriving (Show, Eq)

data MouseManipulator = MouseManipulator {
  _mouseManipulator_pos    :: XY
  , _mouseManipulator_type :: MouseManipulatorType
  -- back reference to object being manipulated?
  -- or just use a function
}

type MouseManipulatorSet = [MouseManipulator]
type ManipulatorIndex = Int

-- questionable manipulator helper functions
findFirstMouseManipulator :: XY -> MouseManipulatorSet -> Maybe ManipulatorIndex
findFirstMouseManipulator pos = L.findIndex (\mm -> _mouseManipulator_pos mm == pos)

-- TODO rename
-- TODO do not process mouseDrag State in here.
manipulateWhatever :: SelectionManipulatorType -> MouseDrag ->  MouseManipulatorSet -> Maybe ManipulatorIndex -> Maybe ManipulatorIndex
manipulateWhatever smt MouseDrag {..} mms mmi = let
    boxRules = undefined -- TODO rules for choosing box manipulator
  in case _mouseDrag_state of
    MouseDragState_Down -> findFirstMouseManipulator _mouseDrag_to mms
    MouseDragState_Dragging -> case smt of
      _ -> case mmi of
        Just mi -> Just mi
        Nothing -> findFirstMouseManipulator _mouseDrag_to mms
      -- TODO specific rulse for each
      --SMTBox         -> undefined
      --SMTLine        -> undefined
      --SMTText        -> undefined
      --SMTBoundingBox -> undefined
      --_              -> error "unknown selection type"
    _ -> Nothing



-- REDUCERS/REDUCER HELPERS
-- TODO finish this function
toMouseManipulators :: Selection -> MouseManipulatorSet
toMouseManipulators selection = if Seq.length selection > 1
  then
    case Seq.lookup 0 selection of
      Nothing -> []
      Just (rid, _, SEltLabel _ selt) -> case selt of
        SEltBox SBox {..}   -> undefined
          -- _sBox_box
        SEltLine SLine {..} -> undefined
          --_sLine_start
          --_sLine_end
        SEltText SText {..} -> undefined
          --_sText_box
          --_sText_text
        _                   -> []
  else bb where
    fmapfn (rid, _, seltl) = do
      box <- getSEltBox . _sEltLabel_sElt $ seltl
      return (rid, box)
    msboxes = sequence $ fmap fmapfn selection
    bb = undefined


-- TODO all data to pass onto backend/PFOutput should go here
data FrontendOperation =
  FrontendOperation_None
  | FrontendOperation_Pan
  | FrontendOperation_LayerDrag

  -- TODO probably change to (Maybe PFEventTag)
  | FrontendOperation_Manipulate (Maybe PFEventTag) ManipulatorIndex
  | FrontendOperation_Undo
  | FrontendOperation_Selecting LBox
  | FrontendOperation_Select Bool Selection
  deriving (Show, Eq)

-- first pass processing inputs
data EverythingFrontend = EverythingFrontend {
  _everythingFrontend_selectedTool    :: Tool
  , _everythingFrontend_pan           :: XY -- panPos is position of upper left corner of canvas relative to screen
  , _everythingFrontend_mouseDrag     :: MouseDrag -- last mouse dragging state
  , _everythingFrontend_lastOperation :: FrontendOperation

  -- TODO needs a way to pass selection onto backend
} deriving (Show)

-- second pass, taking outputs from PFOutput
data EverythingBackend = EverythingBackend {
  _everythingBackend_selection         :: Selection
  , _everythingBackend_layers          :: Seq LayerDisplay
  , _everythingBackend_manipulators    :: MouseManipulatorSet

  , _everythingBackend_broadPhaseState :: BroadPhaseState
  , _everythingBackend_renderedCanvas  :: RenderedCanvas

}

emptyEverythingFrontend :: EverythingFrontend
emptyEverythingFrontend = EverythingFrontend {
    _everythingFrontend_selectedTool   = Tool_Select
    , _everythingFrontend_pan          = V2 0 0
    , _everythingFrontend_mouseDrag = emptyMouseDrag
    , _everythingFrontend_lastOperation = FrontendOperation_None
  }

emptyEverythingBackend :: EverythingBackend
emptyEverythingBackend = EverythingBackend {
    _everythingBackend_selection    = Seq.empty
    , _everythingBackend_layers       = Seq.empty
    , _everythingBackend_manipulators = []
    , _everythingBackend_broadPhaseState   = emptyBroadPhaseState
    , _everythingBackend_renderedCanvas = emptyRenderedCanvas nilLBox
  }

-- combined output for convenient testing thx
data EverythingCombined_DEBUG = EverythingCombined_DEBUG {
  _everythingCombined_selectedTool     :: Tool
  , _everythingCombined_pan            :: XY -- panPos is position of upper left corner of canvas relative to screen
  , _everythingCombined_mouseDrag      :: MouseDrag -- last mouse dragging state
  , _everythingCombined_lastOperation  :: FrontendOperation
  , _everythingCombined_selection      :: Selection
  , _everythingCombined_layers         :: Seq LayerDisplay
  , _everythingCombined_manipulators   :: MouseManipulatorSet
  , _everythingCombined_broadPhase     :: BroadPhaseState
  , _everythingCombined_renderedCanvas :: RenderedCanvas

  -- from PFOutput, remember to set
  , _everythingCombined_pFState        :: PFState
}

combineEverything :: EverythingFrontend -> EverythingBackend -> PFState -> EverythingCombined_DEBUG
combineEverything EverythingFrontend {..} EverythingBackend {..} pfs = EverythingCombined_DEBUG {
    _everythingCombined_selectedTool =   _everythingFrontend_selectedTool
    , _everythingCombined_pan        = _everythingFrontend_pan
    , _everythingCombined_mouseDrag = _everythingFrontend_mouseDrag
    , _everythingCombined_lastOperation = _everythingFrontend_lastOperation
    , _everythingCombined_selection      = _everythingBackend_selection
    , _everythingCombined_layers       = _everythingBackend_layers
    , _everythingCombined_manipulators = _everythingBackend_manipulators
    , _everythingCombined_broadPhase   = _everythingBackend_broadPhaseState
    , _everythingCombined_renderedCanvas   = _everythingBackend_renderedCanvas

    , _everythingCombined_pFState = pfs
  }

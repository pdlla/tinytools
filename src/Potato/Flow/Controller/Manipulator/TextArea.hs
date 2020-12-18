{-# LANGUAGE RecordWildCards #-}

module Potato.Flow.Controller.Manipulator.TextArea (
  TextAreaHandler(..)
  , TextAreaInputState(..)

  -- exposed for testing
  , makeTextAreaInputState
  , mouseText

) where

import           Relude

import           Potato.Flow.Controller.Handler
import           Potato.Flow.Controller.Input
import           Potato.Flow.Controller.Manipulator.Common
import           Potato.Flow.Entry
import           Potato.Flow.Math
import           Potato.Flow.SElts
import           Potato.Flow.Types

import           Control.Exception
import           Data.Default
import           Data.Dependent.Sum                        (DSum ((:=>)))
import qualified Data.IntMap                               as IM
import qualified Data.Sequence                             as Seq
import qualified Data.Text.Zipper                          as TZ
import           Data.Tuple.Extra


data TextAreaInputState = TextAreaInputState {
  _textAreaInputState_original   :: Text -- needed to properly create DeltaText for undo
  , _textAreaInputState_raw      :: Text -- we can always pull this from selection, but may as well store it (useful for validation)
  , _textAreaInputState_box      :: LBox -- we can always pull this from selection, but may as well store it
  , _textAreaInputState_zipper   :: TZ.TextZipper
  , _textAreaInputState_selected :: Int -- WIP
} deriving (Show)

instance Default TextAreaInputState where
  def = TextAreaInputState "" "" (LBox 0 0) TZ.empty 0

-- TODO I think you need to pad empty lines in the zipper to fill out the box D:
-- ok, no you don't, that's only for the non-paragraph text area that we don't actually have yet
makeTextAreaInputState :: SText -> RelMouseDrag -> TextAreaInputState
makeTextAreaInputState stext rmd = r where
  ogtz = TZ.fromText (_sText_text stext)
  r' = TextAreaInputState {
      _textAreaInputState_original   = _sText_text stext
      , _textAreaInputState_raw = _sText_text stext
      , _textAreaInputState_box = _sText_box stext
      , _textAreaInputState_zipper   = ogtz
      , _textAreaInputState_selected = 0
    }
  r = mouseText (Just r') stext rmd

-- TODO define behavior for when you click outside box or assert
mouseText :: Maybe TextAreaInputState -> SText -> RelMouseDrag -> TextAreaInputState
mouseText mtais stext rmd = r where
  RelMouseDrag MouseDrag {..} = rmd
  r = case mtais of
    Nothing -> makeTextAreaInputState stext rmd
    Just tais -> tais { _textAreaInputState_zipper = newtz } where
      ogtz = _textAreaInputState_zipper tais
      LBox (V2 x y) (V2 w _) = _sText_box stext
      -- TODO clip/overflow/wrap mode
      dl = TZ.displayLines w () () ogtz
      V2 mousex mousey = _mouseDrag_to
      newtz = TZ.goToDisplayLinePosition (mousex-x) (mousey-y) dl ogtz

-- TODO support shift selecting text someday meh
inputText :: TextAreaInputState -> Bool -> SuperSEltLabel -> KeyboardKey -> (TextAreaInputState, Maybe PFEventTag)
inputText tais undoFirst selected kk = (tais { _textAreaInputState_zipper = newZip }, mop) where

  oldZip = _textAreaInputState_zipper tais
  (changed, newZip) = case kk of
    KeyboardKey_Left    -> (False, TZ.left oldZip)
    KeyboardKey_Right   -> (False, TZ.right oldZip)
    KeyboardKey_Up      -> (False, TZ.up oldZip)
    KeyboardKey_Down    -> (False, TZ.down oldZip)

    KeyboardKey_Return  -> (False, TZ.insertChar '\n' oldZip)
    KeyboardKey_Space   -> (False, TZ.insertChar ' ' oldZip)
    KeyboardKey_Char c  -> (False, TZ.insertChar c oldZip)
    KeyboardKey_Paste t -> (False, TZ.insert t oldZip)

    KeyboardKey_Esc                   -> error "unexpected keyboard char (escape should be handled outside)"

  controller = CTagText :=> (Identity $ CText {
      _cText_deltaText = (_textAreaInputState_original tais, TZ.value newZip)
    })
  mop = if changed
    then Just $ PFEManipulate (undoFirst, IM.fromList [(fst3 selected,controller)])
    else Nothing

-- text area handler state and the text it represents are updated independently and they should always be consistent
checkTextAreaHandlerStateIsConsistent :: TextAreaInputState -> SText -> Bool
checkTextAreaHandlerStateIsConsistent TextAreaInputState {..} SText {..} = r where
  LBox _ (V2 w _) = _sText_box
  LBox _ (V2 bw _) = _textAreaInputState_box
  r = _textAreaInputState_raw == _sText_text && w == bw

data TextAreaHandler = TextAreaHandler {
    _textAreaHandler_isActive :: Bool
    , _textAreaHandler_state  :: TextAreaInputState
  }

makeTextAreaHandler :: Selection -> RelMouseDrag -> TextAreaHandler
makeTextAreaHandler selection rmd = case selectionToSuperSEltLabel selection of
  (_,_,SEltLabel _ (SEltText stext)) -> TextAreaHandler {
      _textAreaHandler_isActive = False
      , _textAreaHandler_state = makeTextAreaInputState stext rmd
    }
  (_,_,SEltLabel _ selt) -> error $ "expected SEltText, got " <> show selt


instance PotatoHandler TextAreaHandler where
  pHandlerName _ = handlerName_textArea
  pHandleMouse tah@TextAreaHandler {..} PotatoHandlerInput {..} rmd@(RelMouseDrag MouseDrag {..}) = let
      stext = case selectionToSuperSEltLabel _potatoHandlerInput_selection of
        (_,_,SEltLabel _ (SEltText stext)) -> stext
        (_,_,SEltLabel _ selt) -> error $ "expected SEltText, got " <> show selt
      validateFirst = assert (checkTextAreaHandlerStateIsConsistent _textAreaHandler_state stext)
    in validateFirst $ case _mouseDrag_state of
      MouseDragState_Down -> r where
        clickOutside = does_LBox_contains_XY (_textAreaInputState_box _textAreaHandler_state) _mouseDrag_from
        newState = mouseText (Just _textAreaHandler_state) stext rmd
        r = if clickOutside
          then Nothing
          else Just $ def {
              _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler tah {
                  _textAreaHandler_isActive = True
                  , _textAreaHandler_state = newState
                }
            }

      -- TODO drag select text
      MouseDragState_Dragging -> Just $ captureWithNoChange tah
      MouseDragState_Up -> Just $ def {
          _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler tah {
              _textAreaHandler_isActive = False
            }
        }
      _ -> error "unexpected mouse state passed to handler"


  pHandleKeyboard tah@TextAreaHandler {..} PotatoHandlerInput {..} (KeyboardData k mods) = r where
    -- TODO make this work...
    r = Just $ captureWithNoChange tah

  -- TODO figure this out
  --pSelectionUpdated tah@TextAreaHandler {..} PotatoHandlerInput {..} =

  -- in this case, cancel simply goes back to box handler and does not undo the operation
  -- TODO if cancel was becaues of escape, undo the operation??
  pHandleCancel tah _ = def { _potatoHandlerOutput_nextHandler = Nothing }

  pRenderHandler tah PotatoHandlerInput {..} = HandlerRenderOutput
  pIsHandlerActive = _textAreaHandler_isActive

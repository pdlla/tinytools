-- This handler does the following things 
-- - transform any selection (drag + resize)
-- - create boxes (consider splitting this one out)
-- - go to box text label or text area edit handler

{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-unused-record-wildcards #-}


module Potato.Flow.Controller.Manipulator.Box where

import           Relude

import Potato.Flow.Attachments
import           Potato.Flow.Controller.Handler
import           Potato.Flow.Controller.Input
import           Potato.Flow.Controller.Manipulator.BoxText
import           Potato.Flow.Controller.Manipulator.TextArea
import           Potato.Flow.Controller.Manipulator.Common
import           Potato.Flow.Controller.Types
import           Potato.Flow.Math
import           Potato.Flow.Methods.SEltMethods
import           Potato.Flow.Methods.Shape
import           Potato.Flow.Serialization.Snake
import           Potato.Flow.Types
import           Potato.Flow.OwlItem
import Potato.Flow.Owl
import Potato.Flow.OwlState
import Potato.Flow.Methods.Types
import Potato.Flow.Llama
import           Potato.Flow.Methods.LlamaWorks
import           Potato.Flow.Preview


import           Data.Default
import           Data.Dependent.Sum                         (DSum ((:=>)))
import qualified Data.IntMap                                as IM
import qualified Data.Map as Map
import qualified Data.List                                  as L
import qualified Data.Sequence as Seq

import Control.Exception (assert)



superOwl_isTransformable :: (HasOwlTree o) => SuperOwl -> o -> Bool
superOwl_isTransformable sowl ot = case _owlItem_subItem (_superOwl_elt sowl) of
  OwlSubItemNone -> False
  OwlSubItemFolder _ -> False

  -- THE REASON YOU DID THIS IS TO PREVENT FULLY ATTACHED LINES FROM BEING MOVED (because then thei'r endpoints jump around when the attached objects are destroyed)
  -- TODO FIX THE ABOVE
  -- I forgot why I added this, but in any case, we definitely DO want to transform lines if all it's attached parents are also being transformed
  --OwlSubItemLine sline -> not $
  --  (fromMaybe False $ _sAutoLine_attachStart sline <&> (\att -> hasOwlTree_exists ot (_attachment_target att)))
  --  && (fromMaybe False $ _sAutoLine_attachEnd sline <&> (\att -> hasOwlTree_exists ot (_attachment_target att)))

  
  _ -> True

-- TODO you MAY want to consider adding all lines that have both attachments in the selection to the modify set 
transformableSelection :: PotatoHandlerInput -> Seq SuperOwl
transformableSelection PotatoHandlerInput {..} = transformableSelection' _potatoHandlerInput_pFState _potatoHandlerInput_canvasSelection

transformableSelection' :: OwlPFState -> CanvasSelection -> Seq SuperOwl
transformableSelection' pfs sel = Seq.filter (flip superOwl_isTransformable pfs) (unCanvasSelection sel)


-- TODO rework this stuff, it was written with old assumptions that don't make sense anymore
data MouseManipulatorType = MouseManipulatorType_Corner | MouseManipulatorType_Side | MouseManipulatorType_Point | MouseManipulatorType_Area | MouseManipulatorType_Text deriving (Show, Eq)
data MouseManipulator = MouseManipulator {
  _mouseManipulator_box    :: LBox
  , _mouseManipulator_type :: MouseManipulatorType
  -- back reference to object being manipulated?
  -- or just use a function
}
type MouseManipulatorSet = [MouseManipulator]
type ManipulatorIndex = Int

toMouseManipulators :: OwlPFState -> CanvasSelection -> MouseManipulatorSet
toMouseManipulators pfs selection' = bb where
  union_lBoxes :: NonEmpty LBox -> LBox
  union_lBoxes (x:|xs) = foldl' union_lBox x xs
  selection = transformableSelection' pfs selection'
  fmapfn sowl = _sEltDrawer_box (getDrawer . hasOwlItem_toOwlSubItem $ sowl) pfs
  -- consider filtering out boxes with 0 area, but really _sEltDrawer_box should have return type Maybe LBox
  sboxes = toList $ fmap fmapfn selection
  bb = case sboxes of
    []   -> []
    x:xs -> fmap (flip makeHandleBox (union_lBoxes (x:|xs))) [BH_TL .. BH_A]

findFirstMouseManipulator :: OwlPFState -> RelMouseDrag -> CanvasSelection -> Maybe ManipulatorIndex
findFirstMouseManipulator pfs (RelMouseDrag MouseDrag {..}) selection = r where
  mms = toMouseManipulators pfs selection
  smt = computeSelectionType selection

  -- TODO use select magic here
  normalSel = L.findIndex (\mm -> does_lBox_contains_XY (_mouseManipulator_box mm) _mouseDrag_from) mms
  r = case smt of
    SMTTextArea -> normalSel -- TODO figure out how to differentiate between area / text manipulator
    _       -> normalSel


-- order is manipulator index
data BoxHandleType = BH_TL | BH_TR | BH_BL | BH_BR | BH_A | BH_T | BH_B | BH_L | BH_R  deriving (Show, Eq, Enum)

makeHandleBox ::
  BoxHandleType
  -> LBox -- ^ box being manipulated
  -> MouseManipulator
makeHandleBox bht (LBox (V2 x y) (V2 w h)) = case bht of
  BH_BR -> MouseManipulator box MouseManipulatorType_Corner
  BH_TL -> MouseManipulator box MouseManipulatorType_Corner
  BH_TR -> MouseManipulator box MouseManipulatorType_Corner
  BH_BL -> MouseManipulator box MouseManipulatorType_Corner
  BH_A  -> MouseManipulator box MouseManipulatorType_Area
  _     -> MouseManipulator box MouseManipulatorType_Side
  where
    (px, py) = (0,0) -- pan position
    CanonicalLBox _ _ clbox = canonicalLBox_from_lBox $ LBox (V2 (x+px) (y+py)) (V2 w h)
    nudgex = if w < 0 then 1 else 0
    nudgey = if h < 0 then 1 else 0
    l = x+px-1 + nudgex
    t = y+py-1 + nudgey
    r = x+px+w - nudgex
    b = y+py+h - nudgey
    box = case bht of
      BH_BR -> LBox (V2 r b) (V2 1 1)
      BH_TL -> LBox (V2 l t) (V2 1 1)
      BH_TR -> LBox (V2 r t) (V2 1 1)
      BH_BL -> LBox (V2 l b) (V2 1 1)
      BH_A  -> clbox
      _     -> error "not supported yet"

makeDeltaBox :: BoxHandleType -> XY -> DeltaLBox
makeDeltaBox bht (V2 dx dy) = case bht of
  BH_BR -> DeltaLBox 0 $ V2 dx dy
  BH_TL -> DeltaLBox (V2 dx dy) (V2 (-dx) (-dy))
  BH_TR -> DeltaLBox (V2 0 dy) (V2 dx (-dy))
  BH_BL -> DeltaLBox (V2 dx 0) (V2 (-dx) dy)
  BH_T  -> DeltaLBox (V2 0 dy) (V2 0 (-dy))
  BH_B  -> DeltaLBox 0 (V2 0 dy)
  BH_L  -> DeltaLBox (V2 dx 0) (V2 (-dx) 0)
  BH_R  -> DeltaLBox 0 (V2 dx 0)
  BH_A  -> DeltaLBox (V2 dx dy) (V2 0 0)



-- TODO rename to BoxHandlerType or something
data BoxCreationType = BoxCreationType_None | BoxCreationType_Box | BoxCreationType_Text | BoxCreationType_TextArea | BoxCreationType_DragSelect deriving (Show, Eq)

boxCreationType_isCreation :: BoxCreationType -> Bool
boxCreationType_isCreation bct = bct /= BoxCreationType_None && bct /= BoxCreationType_DragSelect


-- TODO DEPRECATE THIS, replace with ShapeCreation/ModifyHandler, you can't do this yet because:
-- I think ShapeModifyHandler maybe shouldn't handle modifying several objects? But in that case BoxHandler should handle only this case and renamed to MultiObjectHandler or something
-- I think BoxHandler has some special logic for entering text edit mode or something
data BoxHandler = BoxHandler {

    _boxHandler_handle      :: BoxHandleType -- the current handle we are dragging

    -- TODO this is wrong as makeDragOperation does not always return a Llama
    -- rename this to mouseActive or something
    , _boxHandler_undoFirst :: Bool

    -- with this you can use same code for both create and manipulate (create the handler and immediately pass input to it)
    , _boxHandler_creation  :: BoxCreationType
    , _boxHandler_active    :: Bool

    , _boxHandler_downOnLabel :: Bool


    , _boxHandler_prevDeltaLBox :: Maybe DeltaLBox

  } deriving (Show)

makeDragDeltaBox :: BoxHandleType -> RelMouseDrag -> DeltaLBox
makeDragDeltaBox bht rmd = r where
  RelMouseDrag MouseDrag {..} = rmd
  dragDelta = _mouseDrag_to - _mouseDrag_from
  shiftClick = elem KeyModifier_Shift _mouseDrag_modifiers

  boxRestrictedDelta = if shiftClick
    then restrict8 dragDelta
    else dragDelta

  r = makeDeltaBox bht boxRestrictedDelta

-- reduces the DeltaLBox such that the LBox does not invert
-- assumes LBox is canonical and that LBox is not already smaller than the desired constrained size
constrainDeltaLBox :: Int -> DeltaLBox -> LBox -> DeltaLBox
constrainDeltaLBox minsize d1@(DeltaLBox (V2 dx dy) (V2 dw dh)) (LBox _ (V2 w h)) = r where
  optuple e = (e, -e)

  (ndx, ndw) = if dx /= 0 
    then optuple (min (w-minsize) dx)
    else (dx, (max minsize (w+dw)) - w)
  
  (ndy, ndh) = if dy /= 0
    then optuple (min (h-minsize) dy)
    else (dy, (max minsize (h+dh)) - h)

  istranslateonly = dw == 0 && dh == 0
  
  r = if istranslateonly 
    then d1 
    else DeltaLBox (V2 ndx ndy) (V2 ndw ndh)

-- OR you remove the delta portion that already modified the box in preview
makeDragOperationNew :: PotatoHandlerInput -> DeltaLBox -> Maybe Llama
makeDragOperationNew phi dbox = op where
  selection = transformableSelection phi
  selectionl = toList $ transformableSelection phi
  pfs = _potatoHandlerInput_pFState phi
  lboxes = fmap (\sowl -> _sEltDrawer_box (getDrawer . hasOwlItem_toOwlSubItem $ sowl) pfs) selectionl

  -- go through each element in selection and ensure that dbox does not invert that element
  -- DANGER you need to make sure you have sensible bounding box functions or you might put things in a non-resizeable state
  constraineddbox = foldl' (constrainDeltaLBox 1) dbox lboxes

  fmapfn sowl = makeSetLlama (rid, newselt) where
    rid = _superOwl_id sowl
    oldselt = superOwl_toSElt_hack sowl
    -- TODO don't use the CBoundingBox version of that funciton, it's deprecated, write a new one.
    newselt = modify_sElt_with_cBoundingBox True oldselt (CBoundingBox constraineddbox)

  op = if Seq.null selection
    then Nothing
    else Just $ makeCompositionLlama . toList $ (fmap fmapfn selectionl)


makeDragOperation :: PotatoHandlerInput -> DeltaLBox -> Maybe Llama
makeDragOperation phi dbox = op where
  selection = transformableSelection phi
  selectionl = toList $ transformableSelection phi
  
  
  -- go through each element in selection and ensure that dbox does not invert that element
  -- DANGER you need to make sure you have sensible bounding box functions or you might put things in a non-resizeable state
  --pfs = _potatoHandlerInput_pFState phi
  --lboxes = fmap (\sowl -> _sEltDrawer_box (getDrawer . hasOwlItem_toOwlSubItem $ sowl) pfs) selectionl
  --constraineddbox = foldl' (constrainDeltaLBox 0) dbox lboxes

  makeController _ = cmd where
    cmd = CTagBoundingBox :=> (Identity $ CBoundingBox {
      _cBoundingBox_deltaBox = dbox -- constraineddbox
    })

  op = if Seq.null selection
    then Nothing
    else Just $ makePFCLlama . OwlPFCManipulate $ IM.fromList (fmap (\s -> (_superOwl_id s, makeController s)) selectionl)

-- TODO split this handler in two handlers
-- one for resizing selection (including boxes)
-- and one exclusively for creating boxes
instance Default BoxHandler where
  def = BoxHandler {
      _boxHandler_handle       = BH_BR
      , _boxHandler_undoFirst  = False
      , _boxHandler_creation = BoxCreationType_None
      , _boxHandler_active = False
      , _boxHandler_downOnLabel = False
      , _boxHandler_prevDeltaLBox = Nothing
      -- TODO whatever
      --, _boxHandler_wasDragged = False
    }



selectionOnlySBox :: CanvasSelection -> Maybe SBox
selectionOnlySBox (CanvasSelection selection) = if Seq.length selection == 1
  then case superOwl_toSElt_hack (Seq.index selection 0) of
    SEltBox sbox -> Just sbox
    _ -> Nothing
  else Nothing


isMouseOnSelectionSBoxBorder :: CanvasSelection -> RelMouseDrag -> Bool
isMouseOnSelectionSBoxBorder cs (RelMouseDrag MouseDrag {..}) = case selectionOnlySBox cs of
  -- not an SBox selected
  Nothing -> False
  Just sbox -> if sBoxType_hasBorder (_sBox_boxType sbox) && does_lBox_contains_XY (lBox_to_boxLabelBox (_sBox_box sbox)) _mouseDrag_from
    then True
    else False

minusDeltaLBox :: DeltaLBox -> DeltaLBox -> DeltaLBox
minusDeltaLBox (DeltaLBox (V2 dx1 dy1) (V2 dw1 dh1)) (DeltaLBox (V2 dx2 dy2) (V2 dw2 dh2)) = DeltaLBox (V2 (dx1-dx2) (dy1-dy2)) (V2 (dw1-dw2) (dh1-dh2))

instance PotatoHandler BoxHandler where
  pHandlerName _ = handlerName_box
  pHandleMouse bh@BoxHandler {..} phi@PotatoHandlerInput {..} rmd@(RelMouseDrag MouseDrag {..}) = case _mouseDrag_state of

    -- TODO creation should be a separate handler
    MouseDragState_Down | boxCreationType_isCreation _boxHandler_creation ->  Just $ def {
        _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler bh { _boxHandler_active = True }
      }
    -- if shift is held down, ignore inputs, this allows us to shift + click to deselect
    -- TODO consider moving this into GoatWidget since it's needed by many manipulators
    MouseDragState_Down | elem KeyModifier_Shift _mouseDrag_modifiers -> Nothing
    -- in DragSelect case we already have a selection
    MouseDragState_Down | _boxHandler_creation == BoxCreationType_DragSelect  -> assert (not . isParliament_null $ _potatoHandlerInput_selection) r where
        newbh = bh {
            -- drag select case is always BH_A
            _boxHandler_handle = BH_A
            , _boxHandler_active = True
          }
        r = Just def { _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh }
    MouseDragState_Down -> case findFirstMouseManipulator _potatoHandlerInput_pFState rmd _potatoHandlerInput_canvasSelection of
      Nothing -> Nothing



      -- clicked on a manipulator, begin dragging
      Just mi -> r where
        newbh = bh {
            _boxHandler_handle = bht
            , _boxHandler_active = True
            -- label position always intersects BH_A so we do the test in here to see if we clicked on the label area
            , _boxHandler_downOnLabel = if bht == BH_A then isMouseOnSelectionSBoxBorder _potatoHandlerInput_canvasSelection rmd else False
          }
        bht = toEnum mi
        -- special case behavior for BH_A require actually clicking on something on selection
        clickOnSelection = any (doesSEltIntersectPoint _mouseDrag_to . superOwl_toSElt_hack) $ unCanvasSelection _potatoHandlerInput_canvasSelection
        r = if bht /= BH_A || clickOnSelection
          then Just def { _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh }
          else Nothing


    MouseDragState_Dragging -> Just r where
      dragDelta = _mouseDrag_to - _mouseDrag_from
      newEltPos = lastPositionInSelection (_owlPFState_owlTree _potatoHandlerInput_pFState) _potatoHandlerInput_selection

      -- TODO do I use this for box creation? Prob want to restrictDiag or something though
      --shiftClick = elem KeyModifier_Shift _mouseDrag_modifiers
      --boxRestrictedDelta = if shiftClick then restrict8 dragDelta else dragDelta

      boxToAdd = def {
          _sBox_box     = canonicalLBox_from_lBox_ $ LBox _mouseDrag_from dragDelta
          -- consider using _potatoDefaultParameters_boxType instead
          , _sBox_boxType  = if _boxHandler_creation == BoxCreationType_Text
            then SBoxType_BoxText -- TODO pull from params
            else SBoxType_Box
          , _sBox_superStyle = _potatoDefaultParameters_superStyle _potatoHandlerInput_potatoDefaultParameters
          , _sBox_title = def { _sBoxTitle_align = _potatoDefaultParameters_box_label_textAlign _potatoHandlerInput_potatoDefaultParameters }
          , _sBox_text = def { _sBoxText_style = def { _textStyle_alignment = _potatoDefaultParameters_box_text_textAlign _potatoHandlerInput_potatoDefaultParameters } }
        }

      textAreaToAdd = def {
          _sTextArea_box   =  canonicalLBox_from_lBox_ $ LBox _mouseDrag_from dragDelta
          , _sTextArea_text        = Map.empty
          , _sTextArea_transparent = True
        }

      nameToAdd = case _boxHandler_creation of
        BoxCreationType_Box -> "<box>"
        BoxCreationType_Text -> "<text>"
        BoxCreationType_TextArea -> "<textarea>"
        _ -> error "invalid BoxCreationType"

      mdd = makeDragDeltaBox _boxHandler_handle rmd

      mop = case _boxHandler_creation of
        x | x == BoxCreationType_Box || x == BoxCreationType_Text -> Just $ makeAddEltLlama _potatoHandlerInput_pFState newEltPos (OwlItem (OwlInfo nameToAdd) (OwlSubItemBox boxToAdd))
        BoxCreationType_TextArea -> Just $ makeAddEltLlama _potatoHandlerInput_pFState newEltPos (OwlItem (OwlInfo nameToAdd) (OwlSubItemTextArea textAreaToAdd))
        _ -> makeDragOperationNew phi (minusDeltaLBox mdd (fromMaybe (DeltaLBox 0 0) _boxHandler_prevDeltaLBox))

      newbh = bh {
          _boxHandler_undoFirst = True
          -- if we drag, we are no longer in label case
          , _boxHandler_downOnLabel = False
          , _boxHandler_prevDeltaLBox = Just mdd
        }

      -- NOTE, that if we did create a new box, it wil get auto selected and a new BoxHandler will be created for it

      r = def {
          _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh
          , _potatoHandlerOutput_action = case mop of
            Nothing -> HOA_Nothing
            Just op -> HOA_Preview $ Preview (previewOperation_fromUndoFirst _boxHandler_undoFirst) op
        }

    MouseDragState_Up | _boxHandler_downOnLabel -> if isMouseOnSelectionSBoxBorder _potatoHandlerInput_canvasSelection rmd
      -- clicked on the box label area
      -- pass on mouse as MouseDragState_Down is a hack but whatever it works
      -- TODO fix this hack, just have mouse up handle selection in this special case
      then pHandleMouse (makeShapeLabelHandler (_shapeDef_labelImpl boxShapeDef 0) (SomePotatoHandler (def :: BoxHandler)) _potatoHandlerInput_canvasSelection rmd) phi rmd
      else Nothing
    MouseDragState_Up -> r where

      -- TODO do selectMagic here so we can enter text edit modes from multi-selections (you will also need to modify the selection)
      nselected = Seq.length (unCanvasSelection _potatoHandlerInput_canvasSelection)
      selt = superOwl_toSElt_hack <$> selectionToMaybeFirstSuperOwl _potatoHandlerInput_canvasSelection
      isBox = nselected == 1 && case selt of
        Just (SEltBox _) -> True
        _                                    -> False
      isText = nselected == 1 && case selt of
        Just (SEltBox SBox{..}) -> sBoxType_isText _sBox_boxType
        _                                    -> False
      isTextArea = nselected == 1 && case selt of
        Just (SEltTextArea _) -> True
        _ -> False


      -- only enter sub handler if we weren't drag selecting (this includes selecting it from an unselect state without dragging)
      wasNotDragSelecting = not (_boxHandler_creation == BoxCreationType_DragSelect)
      -- only enter subHandler we did not drag (hack, we do this by testing form _boxHandler_undoFirst)
      wasNotActuallyDragging = not _boxHandler_undoFirst
      -- always go straight to handler after creating a new SElt
      isCreation = boxCreationType_isCreation _boxHandler_creation
      r = if (isText || (isBox && not isCreation))
          && (wasNotActuallyDragging || isCreation)
          && wasNotDragSelecting
        -- create box handler and pass on the input (if it was not a text box it will be converted to one by the BoxTextHandler)
        then pHandleMouse (makeShapeTextHandler (_shapeDef_textImpl boxShapeDef) isCreation (SomePotatoHandler (def :: BoxHandler)) _potatoHandlerInput_canvasSelection rmd) phi rmd

        else if isTextArea
          && (wasNotActuallyDragging || isCreation)
          && wasNotDragSelecting
          then let 
            tah = makeTextAreaHandler (SomePotatoHandler (def :: BoxHandler)) _potatoHandlerInput_canvasSelection rmd isCreation in
              if isCreation
                then textAreaHandler_pHandleMouse_onCreation tah phi rmd
                else pHandleMouse tah phi rmd

          -- This clears the handler and causes selection to regenerate a new handler.
          -- Why do we do it this way instead of returning a handler? Not sure, doesn't matter.
          else Just def {
              _potatoHandlerOutput_action = HOA_Preview Preview_MaybeCommit
              -- doesn't work, see comments where _boxHandler_undoFirst is defined
              --_potatoHandlerOutput_action = if _boxHandler_undoFirst then HOA_Preview Preview_Commit else HOA_Nothing
            }

        -- TODO if this was a text box creation case, consider entering text edit mode

      -- TODO consider handling special case, handle when you click and release create a box in one spot, create a box that has size 1 (rather than 0 if we did it during MouseDragState_Down normal way)

    MouseDragState_Cancelled -> if _boxHandler_undoFirst 
      then Just def { 
          -- you may or may not want to do this?
          --_potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler (def :: BoxHandler)
          _potatoHandlerOutput_action = HOA_Preview Preview_Cancel 
        } 
      else Just def


  pHandleKeyboard bh phi@PotatoHandlerInput {..} (KeyboardData key _) = r where

    todlbox (x,y) = Just $ DeltaLBox (V2 x y) 0
    mmove = case key of
      KeyboardKey_Left -> todlbox (-1,0)
      KeyboardKey_Right -> todlbox (1,0)
      KeyboardKey_Up -> todlbox (0,-1)
      KeyboardKey_Down -> todlbox (0,1)
      _ -> Nothing

    r = if _boxHandler_active bh
      -- ignore inputs when we're in the middle of dragging
      then Nothing
      else case mmove of
        Nothing -> Nothing
        Just move -> Just r2 where
          mop = makeDragOperationNew phi move
          r2 = def {
              _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler bh
              , _potatoHandlerOutput_action = case mop of
                Nothing -> HOA_Nothing

                -- TODO we want to PO_Start/Continue here, but we need to Preview_Commit somewhere
                Just op -> HOA_Preview $ Preview PO_StartAndCommit op
            }

  pRenderHandler BoxHandler {..} PotatoHandlerInput {..} = r where
    handlePoints = fmap _mouseManipulator_box . filter (\mm -> _mouseManipulator_type mm == MouseManipulatorType_Corner) $ toMouseManipulators _potatoHandlerInput_pFState _potatoHandlerInput_canvasSelection

    {-- 
    -- kind of a hack to put this here, since BoxHandler is generic, but that's how it has to be for now since BoxHandler is also kind of not generic
    -- I guess in the future you might have more specific handlers for each type of owl in which case you can do the thing where the specific handler also has a ref to BoxHandler and you render both (you did this with the text handler already)
    -- TODO and this is an issue becaues you don't want to show the box label handler when you are editing the box label 
    mBoxLabelHandler = case selectionOnlySBox _potatoHandlerInput_canvasSelection of
      Nothing -> Nothing
      Just sbox -> if sBoxType_hasBorder (_sBox_boxType sbox)
        then if w > 1
          then Just $ RenderHandle {
              _renderHandle_box = LBox (V2 (x+1) y) (V2 1 1)
              , _renderHandle_char  = Just 'T'
              , _renderHandle_color = RHC_Cursor
            } 
          else Nothing 
        else Nothing
        where (LBox (V2 x y) (V2 w h)) = _sBox_box sbox

    mcons :: Maybe a -> [a] -> [a]
    mcons ma as = maybe as (:as) ma
    --}

    -- TODO highlight active manipulator if active
    --if (_boxHandler_active)
    r = if not _boxHandler_active && boxCreationType_isCreation _boxHandler_creation
      -- don't render anything if we are about to create a box
      then emptyHandlerRenderOutput
      --else HandlerRenderOutput (mcons mBoxLabelHandler $ fmap defaultRenderHandle handlePoints)
      else HandlerRenderOutput (fmap defaultRenderHandle handlePoints)
      
  pIsHandlerActive bh = if _boxHandler_active bh then HAS_Active_Mouse else HAS_Inactive

  pHandlerTool BoxHandler {..} = case _boxHandler_creation of
    BoxCreationType_Box -> Just Tool_Box
    BoxCreationType_Text -> Just Tool_Text
    BoxCreationType_TextArea -> Just Tool_TextArea
    _ -> Nothing



-- WIP STARTS HERE 



-- TODO move this to a more appropriate place
data ShapeType = ShapeType_Unknown | ShapeType_Box | ShapeType_Ellipse deriving (Show, Eq)



boxShapeDef :: ShapeDef SBox
boxShapeDef = ShapeDef {
    _shapeDef_name = "SBox"
    , _shapeDef_create = \pdp lbox -> OwlItem (OwlInfo "<box>") $ OwlSubItemBox def {
        _sBox_box = lbox
        , _sBox_boxType = SBoxType_Box
        , _sBox_superStyle = _potatoDefaultParameters_superStyle pdp
        , _sBox_title = def { _sBoxTitle_align = _potatoDefaultParameters_box_label_textAlign pdp }
        , _sBox_text = def { _sBoxText_style = def { _textStyle_alignment = _potatoDefaultParameters_box_text_textAlign pdp } }
      }
    , _shapeDef_impl = \sbox -> ShapeImpl {
      _shapeImpl_updateFromLBox = \rid lbox -> curry makeSetLlama rid $ SEltBox (sbox { _sBox_box = lbox })
      , _shapeImpl_toLBox = _sBox_box sbox
      , _shapeImpl_textArea = if sBoxType_isText (_sBox_boxType sbox) 
        then Just (getSBoxTextBox sbox)
        else Nothing 
      , _shapeImpl_textLabels = if sBoxType_hasBorder (_sBox_boxType sbox) 
        then [canonicalLBox_from_lBox (lBox_to_boxLabelBox (_sBox_box sbox))]
        else []
      , _shapeImpl_startingAttachments = if sBoxType_hasBorder (_sBox_boxType sbox)
        then []
        else availableAttachLocationsFromLBox True (_sBox_box sbox)
      , _shapeImpl_draw = sBox_drawer sbox
    }
    , _shapeDef_labelImpl = \i -> assert (i == 0) boxLabelImpl
    , _shapeDef_textImpl = boxTextImpl
  }

shapeType_to_owlItem :: PotatoDefaultParameters -> CanonicalLBox -> ShapeDef o -> OwlItem
shapeType_to_owlItem pdp clbox impl = _shapeDef_create impl pdp (lBox_from_canonicalLBox clbox)

-- new handler stuff
data ShapeCreationHandler = ShapeCreationHandler {

    _shapeCreationHandler_handle      :: BoxHandleType -- the current handle we are dragging

    -- TODO this is wrong as makeDragOperation does not always return a Llama
    -- rename this to mouseActive or something
    , _shapeCreationHandler_undoFirst :: Bool
    , _shapeCreationHandler_active    :: Bool

    , _shapeCreationHandler_prevDeltaLBox :: Maybe DeltaLBox

    , _shapeCreationHandler_shapeType :: ShapeType

  } deriving (Show)

instance Default ShapeCreationHandler where
  def = ShapeCreationHandler {

      --TODO DELETE ME, just replace with BH_BR
      _shapeCreationHandler_handle       = BH_BR

      , _shapeCreationHandler_undoFirst  = False
      , _shapeCreationHandler_active = False
      , _shapeCreationHandler_prevDeltaLBox = Nothing
      , _shapeCreationHandler_shapeType = ShapeType_Unknown
    }


instance PotatoHandler ShapeCreationHandler where
  pHandlerName _ = handlerName_shape
  pHandleMouse bh@ShapeCreationHandler {..} PotatoHandlerInput {..} rmd@(RelMouseDrag MouseDrag {..}) = case _mouseDrag_state of

    MouseDragState_Down ->  Just $ def {
        _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler bh { _shapeCreationHandler_active = True }
      }

    MouseDragState_Dragging -> Just r where
      dragDelta = _mouseDrag_to - _mouseDrag_from
      newEltPos = lastPositionInSelection (_owlPFState_owlTree _potatoHandlerInput_pFState) _potatoHandlerInput_selection

      -- TODO do I use this for box creation? Prob want to restrictDiag or something though
      --shiftClick = elem KeyModifier_Shift _mouseDrag_modifiers
      --boxRestrictedDelta = if shiftClick then restrict8 dragDelta else dragDelta

      mdd = makeDragDeltaBox _shapeCreationHandler_handle rmd

      someShapeDef = case _shapeCreationHandler_shapeType of
        ShapeType_Box -> SomeShapeDef boxShapeDef
        ShapeType_Ellipse -> SomeShapeDef ellipseShapeDef
        ShapeType_Unknown -> error "attempting to use ShapeCreationHandler with ShapeType_Unknown"

      mop = case someShapeDef of
        SomeShapeDef shapeDef -> Just $ makeAddEltLlama _potatoHandlerInput_pFState newEltPos $ 
          shapeType_to_owlItem _potatoHandlerInput_potatoDefaultParameters (canonicalLBox_from_lBox $ LBox _mouseDrag_from dragDelta) shapeDef

      newbh = bh {
          _shapeCreationHandler_undoFirst = True
          , _shapeCreationHandler_prevDeltaLBox = Just mdd
        }

      -- NOTE, that if we did create a new box, it wil get auto selected and a new BoxHandler will be created for it

      r = def {
          _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh
          , _potatoHandlerOutput_action = case mop of
            Nothing -> HOA_Nothing
            Just op -> HOA_Preview $ Preview (previewOperation_fromUndoFirst _shapeCreationHandler_undoFirst) op
        }

    MouseDragState_Up -> r where
      shapeModifyHandler = shapeModifyHandlerFromSelection _potatoHandlerInput_canvasSelection
      nextHandler = case _shapeModifyHandler_shapeType shapeModifyHandler of
        ShapeType_Unknown -> Nothing
        _ -> Just $ SomePotatoHandler shapeModifyHandler
      r = Just def {
          _potatoHandlerOutput_action = HOA_Preview Preview_MaybeCommit
          , _potatoHandlerOutput_nextHandler = nextHandler
        }

    MouseDragState_Cancelled -> if _shapeCreationHandler_undoFirst 
      then Just def { 
          -- you may or may not want to do this?
          --_potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler (def :: BoxHandler)
          _potatoHandlerOutput_action = HOA_Preview Preview_Cancel 
        } 
      else Just def


  pRenderHandler ShapeCreationHandler {..} PotatoHandlerInput {..} = r where
    handlePoints = fmap _mouseManipulator_box . filter (\mm -> _mouseManipulator_type mm == MouseManipulatorType_Corner) $ toMouseManipulators _potatoHandlerInput_pFState _potatoHandlerInput_canvasSelection

    r = if not _shapeCreationHandler_active
      -- don't render anything if we are about to create a box
      then emptyHandlerRenderOutput
      --else HandlerRenderOutput (mcons mBoxLabelHandler $ fmap defaultRenderHandle handlePoints)
      else HandlerRenderOutput (fmap defaultRenderHandle handlePoints)
      
  pIsHandlerActive bh = if _shapeCreationHandler_active bh then HAS_Active_Mouse else HAS_Inactive

  pHandlerTool ShapeCreationHandler {..} = Just Tool_Shape


data ShapeModifyHandler = ShapeModifyHandler {

    _shapeModifyHandler_handle      :: BoxHandleType -- the current handle we are dragging

    -- TODO this is wrong as makeDragOperation does not always return a Llama
    -- rename this to mouseActive or something
    , _shapeModifyHandler_undoFirst :: Bool
    , _shapeModifyHandler_active    :: Bool
    , _shapeModifyHandler_downOnLabel :: Maybe Int
    , _shapeModifyHandler_isDragSelect :: Bool

    , _shapeModifyHandler_prevDeltaLBox :: Maybe DeltaLBox

    , _shapeModifyHandler_shapeType :: ShapeType

  } deriving (Show)

instance Default ShapeModifyHandler where
  def = ShapeModifyHandler {
      _shapeModifyHandler_handle       = BH_BR
      , _shapeModifyHandler_undoFirst  = False
      , _shapeModifyHandler_active = False
      , _shapeModifyHandler_downOnLabel = Nothing
      , _shapeModifyHandler_isDragSelect = False
      , _shapeModifyHandler_prevDeltaLBox = Nothing
      , _shapeModifyHandler_shapeType = ShapeType_Box
    }

shapeModifyHandlerFromSelection :: CanvasSelection -> ShapeModifyHandler
shapeModifyHandlerFromSelection cs = r where 
  (shapeType, _) = case superOwl_toSElt_hack <$> selectionToMaybeFirstSuperOwl cs of
    Just (SEltBox sbox) -> (ShapeType_Box, _shapeDef_impl boxShapeDef sbox)
    Just (SEltEllipse sellipse) -> (ShapeType_Ellipse, _shapeDef_impl ellipseShapeDef sellipse)
    _ -> (ShapeType_Unknown, emptyShapeImpl)
  r = def {
    _shapeModifyHandler_shapeType = shapeType
  }


findWhichTextLabelMouseIsOver :: ShapeImpl -> ShapeModifyHandler -> RelMouseDrag -> Maybe Int
findWhichTextLabelMouseIsOver shapeImpl ShapeModifyHandler {..} (RelMouseDrag MouseDrag {..}) = 
  L.findIndex (\lbox -> does_lBox_contains_XY (lBox_from_canonicalLBox lbox) _mouseDrag_from) $ _shapeImpl_textLabels shapeImpl


instance PotatoHandler ShapeModifyHandler where
  pHandlerName _ = handlerName_shapeModify
  pHandleMouse bh@ShapeModifyHandler {..} phi@PotatoHandlerInput {..} rmd@(RelMouseDrag MouseDrag {..}) = let
      selt = superOwl_toSElt_hack $ selectionToFirstSuperOwl _potatoHandlerInput_canvasSelection

      -- TODO we should combine ShapeImpl with ShapeDef and add type param to ShapeModifyHandler so we don't have to do this weirdness
      (shapeDef, shapeImpl) = case (_shapeModifyHandler_shapeType, selt) of
        (ShapeType_Box, SEltBox sbox) -> (boxShapeDef, _shapeDef_impl boxShapeDef sbox)
        (ShapeType_Ellipse, SEltEllipse sellipse) -> (boxShapeDef, _shapeDef_impl ellipseShapeDef sellipse)
        (x, y) -> error ("attempting to use ShapeModifyHandler with (" <> show x <> ", " <> show y <> ")")

    in case _mouseDrag_state of

      -- if shift is held down, ignore inputs, this allows us to shift + click to deselect
      -- TODO consider moving this into GoatWidget since it's needed by many manipulators
      MouseDragState_Down | elem KeyModifier_Shift _mouseDrag_modifiers -> Nothing
      -- in DragSelect case we already have a selection
      MouseDragState_Down | _shapeModifyHandler_isDragSelect  -> assert (not . isParliament_null $ _potatoHandlerInput_selection) r where
          newbh = bh {
              -- drag select case is always BH_A
              _shapeModifyHandler_handle = BH_A
              , _shapeModifyHandler_active = True
            }
          r = Just def { _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh }

      MouseDragState_Down -> case findFirstMouseManipulator _potatoHandlerInput_pFState rmd _potatoHandlerInput_canvasSelection of
        Nothing -> Nothing

        -- clicked on a manipulator, begin dragging
        Just mi -> r where
          newbh = bh {
              _shapeModifyHandler_handle = bht
              , _shapeModifyHandler_active = True
              , _shapeModifyHandler_downOnLabel = findWhichTextLabelMouseIsOver shapeImpl bh rmd
            }
          bht = toEnum mi
          -- special case behavior for BH_A require actually clicking on something on selection
          clickOnSelection = any (doesSEltIntersectPoint _mouseDrag_to . superOwl_toSElt_hack) $ unCanvasSelection _potatoHandlerInput_canvasSelection
          r = if bht /= BH_A || clickOnSelection
            then Just def { _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh }
            else Nothing

      MouseDragState_Dragging -> Just r where
        -- TODO do I use this for box creation? Prob want to restrictDiag or something though
        --shiftClick = elem KeyModifier_Shift _mouseDrag_modifiers
        --boxRestrictedDelta = if shiftClick then restrict8 dragDelta else dragDelta

        mdd = makeDragDeltaBox _shapeModifyHandler_handle rmd

        -- NOTE this operation works with many shapes, not just a single shape, do we want to make the many shape one a separate handler?
        -- TODO should we use _shapeImpl_updateFromLBox instead?
        mop = makeDragOperationNew phi (minusDeltaLBox mdd (fromMaybe (DeltaLBox 0 0) _shapeModifyHandler_prevDeltaLBox))

        newbh = bh {
            _shapeModifyHandler_undoFirst = True
            -- if we drag, we are no longer in label case
            , _shapeModifyHandler_downOnLabel = Nothing
            , _shapeModifyHandler_prevDeltaLBox = Just mdd
          }

        r = def {
            _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler newbh
            , _potatoHandlerOutput_action = case mop of
              Nothing -> HOA_Nothing
              Just op -> HOA_Preview $ Preview (previewOperation_fromUndoFirst _shapeModifyHandler_undoFirst) op
          }

      MouseDragState_Up | isJust _shapeModifyHandler_downOnLabel -> if findWhichTextLabelMouseIsOver shapeImpl bh rmd == _shapeModifyHandler_downOnLabel
        -- clicked on the text label area
        then case _shapeModifyHandler_downOnLabel of
          Just i -> pHandleMouse (makeShapeLabelHandler (_shapeDef_labelImpl shapeDef i) (SomePotatoHandler (def :: BoxHandler)) _potatoHandlerInput_canvasSelection rmd) phi rmd
          Nothing -> error "impossible"
        else Nothing

      MouseDragState_Up -> r where

        -- TODO do selectMagic here so we can enter text edit modes from multi-selections (you will also need to modify the selection)
        nselected = Seq.length (unCanvasSelection _potatoHandlerInput_canvasSelection)
        mselt = superOwl_toSElt_hack <$> selectionToMaybeFirstSuperOwl _potatoHandlerInput_canvasSelection
        isBox = nselected == 1 && case mselt of
          Just (SEltBox _) -> True
          _                                    -> False
        isText = nselected == 1 && case mselt of
          Just (SEltBox SBox{..}) -> sBoxType_isText _sBox_boxType
          _                                    -> False


        -- only enter sub handler if we weren't drag selecting (this includes selecting it from an unselect state without dragging)
        wasNotDragSelecting = not _shapeModifyHandler_isDragSelect
        -- only enter subHandler we did not drag (hack, we do this by testing form _boxHandler_undoFirst)
        wasNotActuallyDragging = not _shapeModifyHandler_undoFirst
        r = if (isText || isBox)
            && wasNotActuallyDragging
            && wasNotDragSelecting

          -- TODO make BoxTextHandler generic to shapes
          -- create box handler and pass on the input (if it was not a text box it will be converted to one by the BoxTextHandler)
          then pHandleMouse (makeShapeTextHandler (_shapeDef_textImpl shapeDef) False (SomePotatoHandler (def :: BoxHandler)) _potatoHandlerInput_canvasSelection rmd) phi rmd
          -- This clears the handler and causes selection to regenerate a new handler.
          -- Why do we do it this way instead of returning a handler? Not sure, doesn't matter.
          else Just def {
              _potatoHandlerOutput_action = HOA_Preview Preview_MaybeCommit
              -- doesn't work, see comments where _boxHandler_undoFirst is defined
              --_potatoHandlerOutput_action = if _boxHandler_undoFirst then HOA_Preview Preview_Commit else HOA_Nothing
            }

      MouseDragState_Cancelled -> if _shapeModifyHandler_undoFirst 
        then Just def { 
            -- you may or may not want to do this?
            --_potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler (def :: BoxHandler)
            _potatoHandlerOutput_action = HOA_Preview Preview_Cancel 
          } 
        else Just def


  pHandleKeyboard bh phi@PotatoHandlerInput {..} (KeyboardData key _) = r where

    todlbox (x,y) = Just $ DeltaLBox (V2 x y) 0
    mmove = case key of
      KeyboardKey_Left -> todlbox (-1,0)
      KeyboardKey_Right -> todlbox (1,0)
      KeyboardKey_Up -> todlbox (0,-1)
      KeyboardKey_Down -> todlbox (0,1)
      _ -> Nothing

    r = if _shapeModifyHandler_active bh
      -- ignore inputs when we're in the middle of dragging
      then Nothing
      else case mmove of
        Nothing -> Nothing
        Just move -> Just r2 where
          mop = makeDragOperationNew phi move
          r2 = def {
              _potatoHandlerOutput_nextHandler = Just $ SomePotatoHandler bh
              , _potatoHandlerOutput_action = case mop of
                Nothing -> HOA_Nothing

                -- TODO we want to PO_Start/Continue here, but we need to Preview_Commit somewhere
                Just op -> HOA_Preview $ Preview PO_StartAndCommit op
            }

  pRenderHandler ShapeModifyHandler {..} PotatoHandlerInput {..} = r where
    handlePoints = fmap _mouseManipulator_box . filter (\mm -> _mouseManipulator_type mm == MouseManipulatorType_Corner) $ toMouseManipulators _potatoHandlerInput_pFState _potatoHandlerInput_canvasSelection

    -- TODO highlight active manipulator if active
    --if (_boxHandler_active)
    r = HandlerRenderOutput (fmap defaultRenderHandle handlePoints)
      
  pIsHandlerActive bh = if _shapeModifyHandler_active bh then HAS_Active_Mouse else HAS_Inactive


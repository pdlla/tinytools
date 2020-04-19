{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE RecursiveDo        #-}
{-# LANGUAGE TemplateHaskell    #-}

module Potato.Flow.Reflex.Cmd (
  PFCmdTag(..)
  , PFCmd
  , PFCmdMap
  , PFCmdStack
  , selectDo
  , selectUndo

  --, TESTTag(..)
) where

import           Relude

import           Reflex
import           Reflex.Data.ActionStack
import           Reflex.Potato.Helpers

import           Potato.Flow.Math
import           Potato.Flow.Reflex.Layers
import           Potato.Flow.Reflex.Manipulators
import           Potato.Flow.Reflex.RElts
import           Potato.Flow.SElts


import qualified Data.Dependent.Map              as DM
import qualified Data.Dependent.Sum              as DS
import qualified Data.GADT.Compare
import           Data.GADT.Compare.TH
import qualified Text.Show


{- DELETE

import           Data.Maybe                      (fromJust)
import           Language.Haskell.TH

data TESTTag a where
  TT1 :: TESTTag Int
  TT2 :: TESTTag String
  TT3 :: TESTTag Int
deriveGEq      (fromJust <$> lookupTypeName "TESTTag")
deriveGCompare ''TESTTag
-}

data PFCmdTag t a where
  PFCNewElts :: PFCmdTag t (NonEmpty (REltLabel t)) -- TODO needs LayerPos, right now it just adds to the end
  PFCDeleteElt :: PFCmdTag t (LayerPos, REltLabel t)
  --PFCReorder :: PFCmdTag t (REltId, LayerPos)
  --PFCPaste :: PFCmdTag t ([SElt t], LayerPos)
  --PFCDuplicate :: PFCmdTag t [REltId]
  PFCManipulate :: PFCmdTag t (ControllerWithId)
  -- TODO maybe there is better type that can make use of Delta type class for scaling many
  PFCManipulateMany :: PFCmdTag t ([REltId], (LBox, LBox)) -- ^ (before, after)

instance Generic  (PFCmdTag t a)


-- TODO use deriveArgDict stuff to do automatically derived show instance
--instance Show  (PFCmdTag t a)
-- this still doesn't get us Show (DSum PFCmdTag f) :(
instance Text.Show.Show (PFCmdTag t a) where
  show PFCNewElts        = "PFCNewElts"
  show PFCDeleteElt      = "PFCDeleteElt"
  show PFCManipulate     = "PFCManipulate"
  show PFCManipulateMany = "PFCManipulateMany"

instance Data.GADT.Compare.GEq (PFCmdTag t) where
  geq PFCNewElts PFCNewElts               = do return Data.GADT.Compare.Refl
  geq PFCDeleteElt PFCDeleteElt           = do return Data.GADT.Compare.Refl
  geq PFCManipulate PFCManipulate         = do return Data.GADT.Compare.Refl
  geq PFCManipulateMany PFCManipulateMany = do return Data.GADT.Compare.Refl

instance Data.GADT.Compare.GCompare (PFCmdTag t) where
  gcompare PFCNewElts PFCNewElts = runGComparing $ (do return Data.GADT.Compare.GEQ)
  gcompare PFCNewElts _ = Data.GADT.Compare.GLT
  gcompare _ PFCNewElts = Data.GADT.Compare.GGT
  gcompare PFCDeleteElt PFCDeleteElt = runGComparing $ (do return Data.GADT.Compare.GEQ)
  gcompare PFCDeleteElt _ = Data.GADT.Compare.GLT
  gcompare _ PFCDeleteElt = Data.GADT.Compare.GGT
  gcompare PFCManipulate PFCManipulate = runGComparing $ (do return Data.GADT.Compare.GEQ)
  gcompare PFCManipulate _ = Data.GADT.Compare.GLT
  gcompare _ PFCManipulate = Data.GADT.Compare.GGT
  gcompare PFCManipulateMany PFCManipulateMany = runGComparing $ (do return Data.GADT.Compare.GEQ)
  gcompare PFCManipulateMany _ = Data.GADT.Compare.GLT
  gcompare _ PFCManipulateMany = Data.GADT.Compare.GGT

type PFCmd t = DS.DSum (PFCmdTag t) Identity
type PFCmdMap t = DM.DMap (PFCmdTag t) Identity

type PFCmdStack t = ActionStack t (PFCmd t)

selectDo :: forall t a. (Reflex t)
  => PFCmdStack t
  -> PFCmdTag t a
  -> Event t a
selectDo = actionStack_makeDoSelector

selectUndo :: forall t a. (Reflex t)
  => PFCmdStack t
  -> PFCmdTag t a
  -> Event t a
selectUndo = actionStack_makeUndoSelector

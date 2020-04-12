{-# LANGUAGE RecordWildCards #-}
--{-# LANGUAGE RecursiveDo     #-}

module Reflex.Stack (
  DynamicStack(..)
  , ModifyDynamicStack(..)
  , defaultModifyDynamicStack
  , holdDynamicStack
) where

import           Relude

import           Reflex
import           Reflex.Potato

import           Control.Monad.Fix

import           Data.Wedge



getHere :: Wedge a b -> Maybe a
getHere c = case c of
  Here x -> Just x
  _      -> Nothing

getThere :: Wedge a b -> Maybe b
getThere c = case c of
  There x -> Just x
  _       -> Nothing


data DynamicStack t a = DynamicStack {
  ds_pushed     :: Event t a
  , ds_popped   :: Event t a
  , ds_contents :: Dynamic t [a]
}

data ModifyDynamicStack t a = ModifyDynamicStack {
  mds_push    :: Event t a
  , mds_pop   :: Event t () -- ^ event to pop an elt from the stack
  , mds_clear :: Event t () -- ^ event to clear the stack, this does NOT trigger any pop events!!
}

-- I can't seem to instantiate from this without getting a could not deduce Reflex t0 error
-- it can't seem to match the t inside and the t outside? I don't understand
defaultModifyDynamicStack :: (Reflex t) => ModifyDynamicStack t a
defaultModifyDynamicStack = ModifyDynamicStack {
    mds_push = never
    , mds_pop = never
    , mds_clear = never
  }

-- helper type for holdDynamicStack
data DSCmd t a = DSCPush a | DSCPop | DSCClear

-- | create a dynamic list
holdDynamicStack ::
  forall t m a. (Reflex t, MonadHold t m, MonadFix m)
  => [a]
  -> ModifyDynamicStack t a
  -> m (DynamicStack t a)
holdDynamicStack initial (ModifyDynamicStack {..}) = do
  let
    changeEvent :: Event t (DSCmd t a)
    changeEvent = leftmostwarn "WARNING: multiple stack events firing at once" [
        fmap DSCPush mds_push
        , fmap (const DSCPop) mds_pop
        , fmap (const DSCClear) mds_clear
      ]

    -- Wedge values:
    -- Here is element that was just pushed
    -- There is element that was just popped
    -- Nowhere is initial state or just popped an empty stack or after a clear
    foldfn :: (DSCmd t a) -> (Wedge a a, [a]) -> PushM t (Wedge a a, [a])
    foldfn (DSCPush x) (_, xs) = return (Here x, x:xs)
    foldfn DSCPop (_, [])      = return (Nowhere, [])
    foldfn DSCPop (_, (x:xs))  = return (There x, xs)
    foldfn DSCClear (_, _)     = return (Nowhere, [])

  sdyn :: Dynamic t (Wedge a a, [a]) <-
    foldDynM foldfn (Nowhere, initial) changeEvent

  let
    changedEv :: Event t (Wedge a a)
    changedEv = fmap fst (updated sdyn)

  return $ DynamicStack {
      ds_pushed = fmapMaybe getHere changedEv
      , ds_popped = fmapMaybe getThere changedEv
      , ds_contents = fmap snd sdyn
    }
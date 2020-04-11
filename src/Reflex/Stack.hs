{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}

module Reflex.Stack (
  DynamicStack(..)
  , DynamicStack(..)
  , defaultModifyDynamicStack
  , holdDynamicStack
) where

import           Relude

import           Reflex

import           Control.Monad.Fix

import           Data.Dependent.Sum
import           Data.List.Index
import           Data.Wedge


data DynamicStack t a = DynamicStack {
  ds_pushed   :: Event t a
  , ds_popped :: Event t a
}

data ModifyDynamicStack t a = ModifyDynamicStack {
  -- first tuple is method producing element to add from an event of when the element is removed
  --mds_push_rec :: (Reflex t) => (Event t () -> PushM t a, Event t ())
  mds_push_rec :: (Reflex t) => (Event t (Event t () -> PushM t a))
  , mds_pop    :: Event t ()
}

defaultModifyDynamicStack :: (Reflex t) => ModifyDynamicStack t a
defaultModifyDynamicStack = ModifyDynamicStack {
    mds_push_rec = never
    , mds_pop = never
  }

-- | helper type for holdDynamicStack
-- left event output type is a callback for constructing the element to be added
-- right event output type is unit and is the pop command
type EvType t a = Either (Event t () -> PushM t a) ()

-- | create a dynamic list
holdDynamicStack ::
  forall t m a. (Reflex t, MonadHold t m, MonadFix m)
  => [a]
  -> ModifyDynamicStack t a
  -> m (DynamicStack t a)
holdDynamicStack initial (ModifyDynamicStack {..}) = mdo
  let
    -- left is add, right is remove
    changeEvent :: Event t (NonEmpty (EvType t a))
    changeEvent = mergeList [fmap Left $ mds_push_rec, fmap Right mds_pop]

    -- here is add
    -- there is remove
    foldfn :: (EvType t a) -> (Wedge a a, [a]) -> PushM t (Wedge a a, [a])
    foldfn (Left makeEltCb) (_, xs) = do
      let
        removeEltEvent = fmapMaybe (\n-> if n == length xs - 1 then Just () else Nothing) popAtEvent
      x <- makeEltCb removeEltEvent
      return (Here x, x:xs)
    foldfn (Right ()) (_, []) = return (Nowhere, [])
    foldfn (Right ()) (_, (x:xs)) = return (There x, xs)

    -- this is prob something like flip (foldM (flip foldfn))
    foldfoldfn :: [(EvType t a)] -> (Wedge a a, [a]) -> PushM t (Wedge a a, [a])
    foldfoldfn [] b     = return b
    foldfoldfn (a:as) b = foldfn a b >>= foldfoldfn as

  dynInt :: Dynamic t (Wedge a a, [a]) <- foldDynM foldfoldfn (Nowhere, []) (fmap toList changeEvent)

  let
    evInt = fmap fst (updated dynInt)

    evPushSelect c = case c of
      Here x -> Just x
      _      -> Nothing
    evPopSelect c = case c of
      There x -> Just x
      _       -> Nothing

    popEvent = fmapMaybe evPopSelect evInt
    popAtEvent = tag (fmap (length . snd) (current dynInt)) popEvent

  return $ DynamicStack {
      ds_pushed = fmapMaybe evPushSelect evInt
      , ds_popped = popEvent
    }

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecursiveDo #-}


-- Alternative representation of dags that combines the simple graph
-- representation from the "DagSimple" module with the tree
-- representation. The goal of this representation is to reduce the
-- overhead of the graph representation for graphs with little or no
-- sharing.

module DagFree where

import qualified DagSimple

import DagSimple (Node, root, edges, nodeCount)

import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap

import qualified Data.Foldable as Foldable
import Data.Foldable (Foldable)
import Data.Traversable (Traversable)
import qualified Data.Traversable as Traversable

import Control.Monad.State

import Control.Monad.ST
import Data.STRef
import qualified Data.Vector as Vec
import qualified Data.Vector.Generic.Mutable as MVec
import Data.Maybe

import AG

type Dag f = DagSimple.Dag (Free f)


-- | This function runs an AG on a dag.
runAGDag :: forall f d u .Traversable f
    => (d -> d -> d)   -- ^ Resolution of top-down state
    -> Syn' f (u,d) u  -- ^ Bottom-up state propagation
    -> Inh' f (u,d) d  -- ^ Top-down state propagation
    -> (u -> d)        -- ^ Initial top-down state
    -> Dag f
    -> u
runAGDag res syn inh dinit g = uFin where
    uFin = umapFin IntMap.! root g
    dFin = dinit uFin
    run :: d -> Free f Node -> (u, IntMap d)
    run d (Ret x) = (umapFin IntMap.! x, IntMap.singleton x d)
    run d (In t)  = (u, dmapLoc) where
        u = explicit syn (u,d) unNumbered result
        m = explicit inh (u,d) unNumbered result
        (result, (dmapLoc,_)) = runState (Traversable.mapM run' t) (IntMap.empty,0)
        run' :: Free f Node -> State (IntMap d, Int) (Numbered ((u,d)))
        run' s = do
            (oldDmap,i) <- get
            let d' = lookupNumMap d i m
                (u',dmap') = run d' s
            let j = i+1
            j `seq` put (IntMap.unionWith res dmap' oldDmap, j)
            return (Numbered i (u',d'))
    dmapFin = IntMap.foldr (\ (_,m1) m2 -> IntMap.unionWith res m1 m2) 
           (IntMap.singleton (root g) dFin) result
    umapFin = IntMap.map fst result
    result = IntMap.mapWithKey (\ n t -> run (dmapFin IntMap.! n) t) (edges g)


-- | Alternative implementation of 'runAGDag' that uses mutable
-- vectors for caching intermediate values.

runAGDagST :: forall f d u .Traversable f
    => (d -> d -> d)   -- ^ Resolution of top-down state
    -> Syn' f (u,d) u  -- ^ Bottom-up state propagation
    -> Inh' f (u,d) d  -- ^ Top-down state propagation
    -> (u -> d)        -- ^ Initial top-down state
    -> Dag f
    -> u
runAGDagST res syn inh dinit g = uFin where
    uFin = runST runM
    dFin = dinit uFin
    runM :: forall s . ST s u
    runM = mdo
      dmap <- MVec.new (nodeCount g)
      MVec.set dmap Nothing
      MVec.unsafeWrite dmap (root g) (Just dFin)
      umap <- MVec.new (nodeCount g)
      count <- newSTRef 0
      let run :: d -> Free f Node -> ST s u
          run d (Ret x) = do 
            old <- MVec.unsafeRead dmap x
            let new = case old of
                        Just o -> res o d
                        _      -> d
            MVec.unsafeWrite dmap x (Just new)
            return (umapFin Vec.! x)
          run d (In t)  = mdo 
            let u = explicit syn (u,d) unNumbered result
                m = explicit inh (u,d) unNumbered result
                run' :: Free f Node -> ST s (Numbered (u,d))
                run' s = do 
                  i <- readSTRef count
                  let j = i+1
                  j `seq` writeSTRef count j
                  let d' = lookupNumMap d i m
                  u' <- run d' s
                  return (Numbered i (u',d'))
            writeSTRef count 0
            result <- Traversable.mapM run' t
            return u
          iter (n, t) = do 
            u <- run (fromJust $ dmapFin Vec.! n) t
            MVec.unsafeWrite umap n u
      mapM_ iter (IntMap.toList $ edges g)
      dmapFin <- Vec.unsafeFreeze dmap
      umapFin <- Vec.unsafeFreeze umap
      return (umapFin Vec.! root g)


runRewriteDagST :: forall f g d u .(Traversable f, Functor g, Foldable g)
    => (d -> d -> d)       -- ^ Resolution of top-down state
    -> Syn' f (u,d) u      -- ^ Bottom-up state propagation
    -> Inh' f (u,d) d      -- ^ Top-down state propagation
    -> Rewrite f (u, d) g  -- ^ Homomorphic rewrite
    -> (u -> d)            -- ^ Initial top-down state
    -> Dag f
    -> (u, Dag g)
runRewriteDagST res syn inh rewr dinit g = (uFin, gFin) where
    (uFin,gFin) = runST runM
    dFin = dinit uFin
    runM :: forall s . ST s (u, Dag g)
    runM = mdo
      dmap <- MVec.new (nodeCount g)
      MVec.set dmap Nothing
      MVec.unsafeWrite dmap (root g) (Just dFin)
      umap <- MVec.new (nodeCount g)
      allEqs <- MVec.new (nodeCount g)
      count <- newSTRef 0
      let iter (node,s) = do 
             let d = fromJust $ dmapFin Vec.! node
             (u,t) <- run d s
             MVec.unsafeWrite umap node u 
             MVec.unsafeWrite allEqs node t
          run :: d -> Free f Node -> ST s (u, Free g Node)
          run d (Ret x) = do 
             old <- MVec.unsafeRead dmap x
             let new = case old of
                         Just o -> res o d
                         _      -> d
             MVec.unsafeWrite dmap x (Just new)
             return (umapFin Vec.! x, Ret x)
          run d (In t)  = mdo 
             let u = explicit syn (u,d) (fst . unNumbered) result
                 m = explicit inh (u,d) (fst . unNumbered) result
                 run' :: Free f Node -> ST s (Numbered ((u,d), Free g Node))
                 run' s = do i <- readSTRef count
                             writeSTRef count $! (i+1)
                             let d' = lookupNumMap d i m
                             (u',t) <- run d' s
                             return (Numbered i ((u',d'), t))
             writeSTRef count 0
             result <- Traversable.mapM run' t
             let t' = join $ fmap (snd . unNumbered) $ explicit rewr (u,d) (fst . unNumbered) result
             return (u, t')
      mapM_ iter $ IntMap.toList $ edges g
      dmapFin <- Vec.unsafeFreeze dmap
      umapFin <- Vec.unsafeFreeze umap
      allEqsFin <- Vec.unsafeFreeze allEqs
      newEqs <- newSTRef IntMap.empty
      let build n = do
             new <- readSTRef newEqs
             unless (IntMap.member n new) $ do
                      let t = allEqsFin Vec.! n
                      writeSTRef newEqs (IntMap.insert n t new)
                      Foldable.mapM_ build t
      build (root g)
      eqs' <- readSTRef newEqs
      return (umapFin Vec.! root g, g {edges = eqs'})


termTree :: Functor f => Tree f -> Dag f
termTree t = DagSimple.Dag 0 (IntMap.singleton 0 (freeTree t)) 1

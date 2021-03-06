{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | This module provides a "reducing" expression evaluator, which reduces
--   away pure, non self-referential aspects of an expression tree, yielding a
--   new expression tree. It does not yet attempt to reduce everything
--   possible, and will always yield a tree with the same meaning as the
--   original. It should be seen as an opportunistic simplifier, but which
--   gives up easily if faced with any potential for ambiguity in the result.

module Nix.Reduce (reduceExpr) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Fix
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Reader (ReaderT(..))
import           Control.Monad.Trans.State (StateT(..))
import           Data.Fix
-- import           Data.Foldable (foldrM)
import           Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as M
import           Data.List.NonEmpty (NonEmpty(..))
import           Data.Maybe (catMaybes)
import           Nix.Atoms
import           Nix.Exec
import           Nix.Expr
import           Nix.Parser
import           Nix.Scope
import           Nix.Utils
import           System.Directory
import           System.FilePath
import           Text.Megaparsec.Pos

newtype Reducer m a = Reducer
    { runReducer :: ReaderT (Maybe FilePath, Scopes (Reducer m) NExprLoc)
                           (StateT (HashMap FilePath NExprLoc) m) a }
    deriving (Functor, Applicative, Alternative, Monad, MonadPlus,
              MonadFix, MonadIO,
              MonadReader (Maybe FilePath, Scopes (Reducer m) NExprLoc),
              MonadState (HashMap FilePath NExprLoc))

instance Has (Maybe FilePath, Scopes m v) (Scopes m v) where
    hasLens f (x, y) = (x,) <$> f y

reduceExpr :: MonadIO m => Maybe FilePath -> NExprLoc -> m NExprLoc
reduceExpr mpath expr
    = (`evalStateT` M.empty)
    . (`runReaderT` (mpath, emptyScopes))
    . runReducer
    $ cata reduce expr

reduce :: forall e m.
           (MonadIO m, Scoped e NExprLoc m,
            MonadReader (Maybe FilePath, Scopes m NExprLoc) m,
            MonadState (HashMap FilePath NExprLoc) m)
       => NExprLocF (m NExprLoc) -> m NExprLoc

reduce (NSym_ ann var) = lookupVar var <&> \case
    Nothing -> Fix (NSym_ ann var)
    Just v  -> v

reduce (NUnary_ uann op arg) = arg >>= \x -> case (op, x) of
    (NNeg, Fix (NConstant_ cann (NInt n))) ->
        return $ Fix $ NConstant_ cann (NInt (negate n))
    (NNot, Fix (NConstant_ cann (NBool b))) ->
        return $ Fix $ NConstant_ cann (NBool (not b))
    _ -> return $ Fix $ NUnary_ uann op x

reduce (NBinary_ bann NApp fun arg) = fun >>= \case
    f@(Fix (NSym_ _ "import")) -> do
        mfile   <- asks fst
        imports <- get
        arg >>= \case
            Fix (NLiteralPath_ pann origPath)
                | Just expr <- M.lookup origPath imports -> pure expr
                | otherwise -> do
                    path  <- liftIO $ pathToDefaultNixFile origPath
                    path' <- liftIO $ pathToDefaultNixFile =<< canonicalizePath
                        (maybe path (\p -> takeDirectory p </> path) mfile)

                    liftIO $ putStrLn $ "Importing file " ++ path'

                    eres <- liftIO $ parseNixFileLoc path'
                    case eres of
                        Failure err  -> error $ "Parse failed: " ++ show err
                        Success x -> do
                            let pos  = SourcePos "Trace.hs" (mkPos 1) (mkPos 1)
                                span = SrcSpan pos pos
                                cur  = NamedVar
                                    (StaticKey "__cur_file" (Just pos) :| [])
                                    (Fix (NLiteralPath_ pann path'))
                                x'   = Fix (NLet_ span [cur] x)
                            modify (M.insert origPath x')
                            local (const (Just path',
                                          emptyScopes @m @NExprLoc)) $ do
                                x'' <- cata reduce x'
                                modify (M.insert origPath x'')
                                return x''
            v -> return $ Fix $ NBinary_ bann NApp f v

    Fix (NAbs_ _ (Param name) body) -> do
        x <- arg
        pushScope (M.singleton name x) (cata reduce body)

    -- jww (2018-04-19): Reduce function application on sets

    f -> Fix . NBinary_ bann NApp f <$> arg

-- jww (2018-04-19): Reduce more binary operations on constants
reduce (NBinary_ bann op larg rarg) = do
    lval <- larg
    rval <- rarg
    case (op, lval, rval) of
        (NPlus, Fix (NConstant_ ann (NInt x)), Fix (NConstant_ _ (NInt y))) ->
            return $ Fix (NConstant_ ann (NInt (x + y)))
        _ -> pure $ Fix $ NBinary_ bann op lval rval

-- jww (2018-04-19): Reduce selection if we can see it all
-- reduce (NSelect aset attr alt) = do

-- jww (2018-04-19): If aset is known to be a set, and attr is a static path,
-- see if we can do the lookup now.
-- reduce (NHasAttr aset attr) =

reduce e@(NSet_ ann binds) = do
    let usesInherit = flip any binds $ \case
            Inherit _ _ -> True
            _ -> False
    if usesInherit
        then do
            -- mv <- lookupVar "callLibs"
            clearScopes @NExprLoc $
            --     (case mv of
            --          Nothing -> id
            --          Just v -> pushScope @NExprLoc (M.singleton "callLibs" v)) $
                    Fix . NSet_ ann <$> traverse sequence binds
        else Fix <$> sequence e

-- Encountering a 'rec set' construction eliminates any hope of inlining
-- definitions.
reduce (NRecSet_ ann binds) =
    clearScopes @NExprLoc $ Fix . NRecSet_ ann <$> traverse sequence binds

-- Encountering a 'with' construction eliminates any hope of inlining
-- definitions.
reduce (NWith_ ann scope body) = do
    -- mv <- lookupVar "callLibs"
    clearScopes @NExprLoc $
    --     (case mv of
    --          Nothing -> id
    --          Just v -> pushScope @NExprLoc (M.singleton "callLibs" v)) $
            fmap Fix $ NWith_ ann <$> scope <*> body

reduce (NLet_ ann binds body) = do
    -- We only handle in order definitions...
    -- s <- go M.empty binds                -- jww (2018-04-20): too slow
    s <- fmap (M.fromList . catMaybes) $ forM binds $ \case
        NamedVar (StaticKey name _ :| []) def -> def >>= \case
            d@(Fix NAbs_ {})      -> pure $ Just (name, d)
            d@(Fix NConstant_ {}) -> pure $ Just (name, d)
            d@(Fix NStr_ {})      -> pure $ Just (name, d)
            _ -> pure Nothing
        _ -> pure Nothing
    fmap Fix $ NLet_ ann <$> traverse sequence binds <*> pushScope s body
  -- where
  --   go m [] = pure m
  --   go m (x:xs) = case x of
  --       NamedVar (StaticKey name _ :| []) def -> do
  --           v <- pushScope m def
  --           go (M.insert name v m) xs
  --       _ -> go m xs

reduce e@(NIf_ _ b t f) = b >>= \case
    Fix (NConstant_ _ (NBool b')) -> if b' then t else f
    _ -> Fix <$> sequence e

reduce e@(NAssert_ _ b body) = b >>= \case
    Fix (NConstant_ _ (NBool b')) | b' -> body
    _ -> Fix <$> sequence e

reduce (NAbs_ ann params body) = do
    params' <- sequence params
    -- Make sure that variable definitions in scope do not override function
    -- arguments.
    let args = case params' of
            Param name -> M.singleton name (Fix (NSym_ ann name))
            ParamSet pset _ _ ->
                M.fromList $ map (\(k, _) -> (k, Fix (NSym_ ann k))) pset
    Fix . NAbs_ ann params' <$> pushScope args body

reduce v = Fix <$> sequence v

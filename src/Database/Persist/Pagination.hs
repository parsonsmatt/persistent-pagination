{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}

-- | This module provides efficient pagination over your database queries.
-- No @OFFSET@ here - we use ranges to do this right!
module Database.Persist.Pagination where

import Control.Applicative
import Conduit
import Data.Foldable
import Control.Applicative (Const(..))
import Data.List (foldl')
import Control.Monad.Reader
import Database.Persist.Sql
import Database.Persist.Class
import qualified Control.Foldl as Foldl
import Lens.Micro

newtype PageSize = PageSize { unPageSize :: Int }
    deriving (Eq, Show)

data SortOrder = Ascend | Descend
    deriving (Eq, Show)

-- | A datatype describing the min and max of a non-empty sequence of
-- records.
data Range t = Range { rangeMin :: t, rangeMax :: t }
    deriving (Eq, Show, Functor)

-- | Users aren't required to put a value in for the range - a value of
-- 'Nothing' is equivalent to saying "unbounded from below."
type DesiredRange t = Range (Maybe t)

instance Ord t => Semigroup (Range t) where
    Range l h <> Range l' h' = Range (min l l') (max h h')

data Page record typ
    = Page
    { pageRecords :: [Entity record]
    , pageRecordCount :: Int
    , pageRange :: Range typ
    , pageDesiredRange :: DesiredRange typ
    , pageField :: EntityField record typ
    , pageFilters :: [Filter record]
    , pageSize :: PageSize
    , pageSortOrder :: SortOrder
    }

rangeToFilters
    :: PersistField typ
    => Range (Maybe typ)
    -> EntityField record typ
    -> [Filter record]
rangeToFilters range field =
    fmap (\m -> field >. m) (toList (rangeMin range))
    ++
    fmap (\m -> field <. m) (toList (rangeMax range))

getPage
    :: forall record backend typ m.
    ( PersistEntity record
    , PersistEntityBackend record ~ backend
    , PersistQueryRead backend
    , Ord typ
    , BaseBackend backend ~ backend
    , PersistField typ
    , MonadIO m
    )
    => [Filter record]
    -- ^ The filters
    -> EntityField record typ
    -- ^ The field to order on.
    -> PageSize
    -- ^ How many records in a page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range
    -> ReaderT backend m (Maybe (Page record typ))
getPage filts field pageSize sortOrder desiredRange = do
    erecs <- selectList filters selectOpts
    case erecs of
        [] ->
            pure Nothing
        rec:recs ->
            pure (Just (mkPage rec recs))
  where
    selectOpts =
        LimitTo (unPageSize pageSize) : case sortOrder of
            Ascend -> [Asc field]
            Descend -> [Desc field]
    filters =
        filts <> rangeToFilters desiredRange field
    mkPage rec recs = Page
        { pageRecords = rec : recs
        , pageRange = mkRange rec recs
        , pageDesiredRange = desiredRange
        , pageField = field
        , pageFilters = filts
        , pageSize = pageSize
        , pageRecordCount = length (rec : recs)
        , pageSortOrder = sortOrder
        }
    mkRange :: Entity record -> [Entity record] -> Range typ
    mkRange rec recs =
        foldl' (<>) (initRange rec) (map initRange recs)
    initRange :: Entity record -> Range typ
    initRange rec =
        Range
            { rangeMin = rec ^. fieldLens field
            , rangeMax = rec ^. fieldLens field
            }

nextPage
    :: ( PersistEntity record
    , PersistEntityBackend record ~ backend
    , PersistQueryRead backend
    , Ord typ
    , BaseBackend backend ~ backend
    , PersistField typ
    , MonadIO m
    )
    => Page record typ -> ReaderT backend m (Maybe (Page record typ))
nextPage Page{..}
    | pageRecordCount < unPageSize pageSize =
        pure Nothing
    | otherwise =
        getPage
            pageFilters
            pageField
            pageSize
            pageSortOrder
            (bumpPageRange pageSortOrder pageDesiredRange pageRange)

bumpPageRange
    :: Ord typ
    => SortOrder
    -> DesiredRange typ
    -> Range typ
    -> DesiredRange typ
bumpPageRange sortOrder (Range mmin mmax) (Range min' max') =
    case sortOrder of
        Ascend ->
            Range (mmin `max` Just max') mmax
        Descend ->
            Range mmin (Just min' <|> (Just min' `min` mmax))

streamEntities
    :: forall record backend typ m a.
    ( PersistEntity record
    , PersistEntityBackend record ~ backend
    , PersistQueryRead backend
    , Ord typ
    , BaseBackend backend ~ backend
    , PersistField typ
    , MonadIO m
    )
    => [Filter record]
    -- ^ The filters
    -> EntityField record typ
    -- ^ The field to order on.
    -> PageSize
    -- ^ How many records in a page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range
    -> ConduitT a (Entity record) (ReaderT backend m) ()
streamEntities filters field pageSize sortOrder range = do
    mpage <- lift (getPage filters field pageSize sortOrder range)
    forM_ mpage loop
  where
    loop page = do
        yieldMany (pageRecords page)
        mpage <- lift (nextPage page)
        forM_ mpage loop

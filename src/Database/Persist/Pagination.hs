{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE DeriveFoldable      #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveTraversable   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | This module provides efficient pagination over your database queries.
-- No @OFFSET@ here - we use ranges to do this right!
--
-- The ideal "range" column for a datatype has a few properties:
--
-- 1. It should have an index. An index on the column will dramatically
--   improve performance on pagination.
-- 2. It should be monotonic - that is, we shouldn't be able to insert new
--   data into the middle of a range. An example would be a @created_at@
--   timestamp field, or a auto-incrementing primary key.
--
-- This module offers two ways to page through a database. You can use the
-- 'streamingEntities' to get a 'ConduitT' of @'Entity' record@ values
-- streaming out. Or, if you'd like finer control, you can use 'getPage'
-- to get the first page of data, and then 'nextPage' to get the next
-- possible page of data.
module Database.Persist.Pagination where

import           Conduit
import           Control.Applicative
import           Control.Applicative    (Const (..))
import qualified Control.Foldl          as Foldl
import           Control.Monad.Reader
import           Data.Foldable
import           Data.List              (foldl')
import           Data.Maybe
import           Data.Monoid
import           Data.Semigroup
import           Database.Persist.Class
import           Database.Persist.Sql
import           Lens.Micro

-- | Stream entities out of the database, only pulling a limited amount
-- into memory at a time.
--
-- @since 0.1.0.0
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
    -- ^ The filters to apply.
    -> EntityField record typ
    -- ^ The field to sort and range over on.
    -> PageSize
    -- ^ How many records in a page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range. Provide @'Range' Nothing Nothing@ if you want
    -- everything in the database.
    -> ConduitT a (Entity record) (ReaderT backend m) ()
streamEntities filters field pageSize sortOrder range = do
    mpage <- lift (getPage filters field pageSize sortOrder range)
    forM_ mpage loop
  where
    loop page = do
        yieldMany (pageRecords page)
        mpage <- lift (nextPage page)
        forM_ mpage loop

-- |
--
-- @since 0.1.0.0
newtype PageSize = PageSize { unPageSize :: Int }
    deriving (Eq, Show)

-- |
--
-- @since 0.1.0.0
data SortOrder = Ascend | Descend
    deriving (Eq, Show)

-- | A datatype describing the min and max of a non-empty sequence of
-- records.
--
-- @since 0.1.0.0
data Range t = Range { rangeMin :: t, rangeMax :: t }
    deriving (Eq, Show, Functor, Foldable, Traversable)

instance Ord t => Semigroup (Range t) where
    Range l h <> Range l' h' = Range (min l l') (max h h')

instance (Bounded t, Ord t) => Monoid (Range t) where
    mempty = Range minBound maxBound

-- | Users aren't required to put a value in for the range - a value of
-- 'Nothing' is equivalent to saying "unbounded from below."
--
-- @since 0.1.0.0
type DesiredRange t = Range (Maybe t)

-- |
--
-- @since 0.1.0.0
data Page record typ
    = Page
    { pageRecords      :: [Entity record]
    , pageRecordCount  :: Int
    , pageRange        :: Range typ
    , pageDesiredRange :: DesiredRange typ
    , pageField        :: EntityField record typ
    , pageFilters      :: [Filter record]
    , pageSize         :: PageSize
    , pageSortOrder    :: SortOrder
    }

-- |
-- |
--
-- @since 0.1.0.0
rangeToFilters
    :: PersistField typ
    => Range (Maybe typ)
    -> EntityField record typ
    -> [Filter record]
rangeToFilters range field =
    fmap (\m -> field >. m) (toList (rangeMin range))
    ++
    fmap (\m -> field <. m) (toList (rangeMax range))

-- |
--
-- @since 0.1.0.0
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
            Ascend  -> [Asc field]
            Descend -> [Desc field]
    filters =
        filts <> rangeToFilters desiredRange field
    mkPage rec recs = flip Foldl.fold (rec:recs) $ do
        let recs' = rec : recs
            rangeDefault = initRange rec
        maxRange <- Foldl.premap (Just . Max . (^. fieldLens field)) Foldl.mconcat
        minRange <- Foldl.premap (Just . Min . (^. fieldLens field)) Foldl.mconcat
        len <- Foldl.length
        pure Page
            { pageRecords = rec : recs
            , pageRange = fromMaybe rangeDefault $
                Range <$> fmap getMin minRange <*> fmap getMax maxRange
            , pageDesiredRange = desiredRange
            , pageField = field
            , pageFilters = filts
            , pageSize = pageSize
            , pageRecordCount = len
            , pageSortOrder = sortOrder
            }
    initRange :: Entity record -> Range typ
    initRange rec =
        Range
            { rangeMin = rec ^. fieldLens field
            , rangeMax = rec ^. fieldLens field
            }

-- |
--
-- @since 0.1.0.0
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

-- |
--
-- @since 0.1.0.0
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

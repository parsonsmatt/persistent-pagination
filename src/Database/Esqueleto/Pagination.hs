{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE DeriveFoldable      #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveTraversable   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE UndecidableInstances #-}

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
module Database.Esqueleto.Pagination
    ( module Database.Esqueleto.Pagination
    , module Types
    ) where

import           Conduit
import qualified Control.Foldl                     as Foldl
import           Control.Monad.Reader              (ReaderT)
import           Data.Foldable                     (for_)
import           Data.Maybe
import           Data.Proxy                        (Proxy(..))
import           Data.Semigroup
import           Database.Persist.Class
import           Database.Persist.Sql
import           Lens.Micro

import           Database.Esqueleto.Experimental    (SqlExpr, SqlQuery, Value,
                                                    asc, desc, limit, orderBy,
                                                    select, val, where_)
import           Database.Esqueleto.Experimental.From (ToFrom, from, table)
import qualified Database.Esqueleto.Experimental    as E
import qualified Database.Esqueleto.Internal.Internal as E.I.I

import           Database.Persist.Pagination.Types as Types

data SqlField select record typ = SqlField
  { sqlAccessor :: select -> SqlExpr (Value typ)
  , haskellAccessor :: record -> typ
  }

entityField
  :: forall record typ.
  ( PersistEntity record
  , PersistField typ
  )
  => EntityField record typ
  -> SqlField (SqlExpr (Entity record)) (Entity record) typ
entityField field = SqlField
  { sqlAccessor = (E.^. field)
  , haskellAccessor = (^. fieldLens field)
  }

joinLeft
  :: SqlField selectLeft left typ
  -> SqlField (selectLeft E.:& selectRight) (left E.:& right) typ
joinLeft innerField = SqlField
  { sqlAccessor = \(left E.:& _) -> sqlAccessor innerField left
  , haskellAccessor = \(left E.:& _) -> haskellAccessor innerField left
  }

joinRight
  :: SqlField selectRight right typ
  -> SqlField (selectLeft E.:& selectRight) (left E.:& right) typ
joinRight innerField = SqlField
  { sqlAccessor = \(_ E.:& right) -> sqlAccessor innerField right
  , haskellAccessor = \(_ E.:& right) -> haskellAccessor innerField right
  }

toJoin :: (a, b) -> (a E.:& b)
toJoin (a, b) = (a E.:& b)

fromJoin :: (a E.:& b) -> (a, b)
fromJoin (a E.:& b) = (a, b)

instance (E.I.I.SqlSelect a ra, E.I.I.SqlSelect b rb) => E.I.I.SqlSelect (a E.:& b) (ra E.:& rb) where
    sqlSelectCols esc = E.I.I.sqlSelectCols esc . fromJoin
    sqlSelectColCount = E.I.I.sqlSelectColCount . fromJoinProxy
      where
        fromJoinProxy :: Proxy (a E.:& b) -> Proxy (a, b)
        fromJoinProxy Proxy = Proxy
    sqlSelectProcessRow = fmap toJoin . E.I.I.sqlSelectProcessRow

-- | Stream entities out of the database, only pulling a limited amount
-- into memory at a time.
--
-- You should use this instead of 'selectSource' because 'selectSource'
-- doesn't really work. It doesn't work at all in MySQL, and it's somewhat
-- sketchy with PostgreSQL and SQLite. This function is guaranteed to use
-- only as much memory as a single page, and if  you tune the page size
-- right, you'll get efficient queries from the database.
--
-- There's an open issue for 'selectSource' not working:
-- <https://github.com/yesodweb/persistent/issues/657 GitHub Issue>.
--
-- @since 0.1.1.0
streamEntities
    :: forall record backend typ m a.
    ( PersistRecordBackend record backend
    , PersistQueryRead backend
    , PersistUniqueRead backend
    , BackendCompatible SqlBackend backend
    , BackendCompatible SqlBackend (BaseBackend backend)
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => (SqlExpr (Entity record) -> SqlExpr (Value Bool))
    -- ^ The filters to apply.
    -> EntityField record typ
    -- ^ The field to sort on. This field should have an index on it, and
    -- ideally, the field should be monotonic - that is, you can only
    -- insert values at either extreme end of the range. A @created_at@
    -- timestamp or autoincremented ID work great for this. Non-monotonic
    -- keys can work too, but you may miss records that are inserted during
    -- a traversal.
    -> PageSize
    -- ^ How many records in a page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range. Provide @'Range' Nothing Nothing@ if you want
    -- everything in the database.
    -> ConduitT a (Entity record) (ReaderT backend m) ()
streamEntities filters field =
  streamFrom (table @record) filters (entityField field)

streamFrom
    :: forall source select record backend typ m i.
    ( ToFrom source select
    , E.I.I.SqlSelect select record
    , PersistQueryRead backend
    , PersistUniqueRead backend
    , BackendCompatible SqlBackend backend
    , BackendCompatible SqlBackend (BaseBackend backend)
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => source
    -> (select -> SqlExpr (Value Bool))
    -> SqlField select record typ
    -> PageSize
    -> SortOrder
    -> DesiredRange typ
    -> ConduitT i record (ReaderT backend m) ()
streamFrom source filters sortKey pageSize sortOrder range = do
    mpage <- lift (getPage source filters sortKey pageSize sortOrder range)
    for_ mpage loop
  where
    loop page = do
        yieldMany (pageRecords page)
        mpage <- lift (nextPage source page)
        for_ mpage loop

-- | Convert a @'DesiredRange' typ@ into a 'SqlQuery' that operates on the
-- range. The 'DesiredRange' is treated as an exclusive range.
--
-- @since 0.1.1.0
rangeToFilters
    :: (PersistField typ)
    => Range (Maybe typ)
    -> SqlField select record typ
    -> select
    -> SqlQuery ()
rangeToFilters range field sqlRec = do
    for_ (rangeMin range) $ \m ->
        where_ $ sqlAccessor field sqlRec E.>. val m
    for_ (rangeMax range) $ \m ->
        where_ $ sqlAccessor field sqlRec E.<. val m

-- | Get the first 'Page' according to the given criteria. This returns
-- a @'Maybe' 'Page'@, because there may not actually be any records that
-- correspond to the query you issue. You can call 'pageRecords' on the
-- result object to get the row of records for this page, and you can call
-- 'nextPage' with the 'Page' object to get the next page, if one exists.
--
-- This function gives you lower level control over pagination than the
-- 'streamEntities' function.
--
-- @since 0.1.1.0
getPage
    :: forall source select record backend typ m.
    ( ToFrom source select
    , E.I.I.SqlSelect select record
    , PersistQueryRead backend
    , PersistUniqueRead backend
    , BackendCompatible SqlBackend backend
    , BackendCompatible SqlBackend (BaseBackend backend)
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => source
    -> (select -> SqlExpr (Value Bool))
    -- ^ The filters to apply.
    -> SqlField select record typ
    -- ^ The field to sort on. This field should have an index on it, and
    -- ideally, the field should be monotonic - that is, you can only
    -- insert values at either extreme end of the range. A @created_at@
    -- timestamp or autogenerated ID work great for this. Non-monotonic
    -- keys can work too, but you may miss records that are inserted during
    -- source traversal.
    -> PageSize
    -- ^ How many records in source page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range. Provide @'Range' Nothing Nothing@ if you want
    -- everything in the database.
    -> ReaderT backend m (Maybe (Page select record typ))
getPage source filts field pageSize sortOrder desiredRange = do
    erecs <- select $ do
        e <- from source
        where_ $ filts e
        rangeToFilters desiredRange field e
        limit (fromIntegral (unPageSize pageSize))
        orderBy . pure $ case sortOrder of
            Ascend  -> asc $ sqlAccessor field e
            Descend -> desc $ sqlAccessor field e
        pure e
    case erecs of
        [] ->
            pure Nothing
        rec:recs ->
            pure (Just (mkPage rec recs))
  where
    mkPage rec recs = flip Foldl.fold (rec:recs) $ do
        let recs' = rec : recs
            rangeDefault = initRange rec
        maxRange <- Foldl.premap (Just . Max . (haskellAccessor field)) Foldl.mconcat
        minRange <- Foldl.premap (Just . Min . (haskellAccessor field)) Foldl.mconcat
        len <- Foldl.length
        pure Page
            { pageRecords = recs'
            , pageRange = fromMaybe rangeDefault $
                Range <$> fmap getMin minRange <*> fmap getMax maxRange
            , pageDesiredRange = desiredRange
            , pageField = field
            , pageFilters = filts
            , pageSize = pageSize
            , pageRecordCount = len
            , pageSortOrder = sortOrder
            }
    initRange :: record -> Range typ
    initRange rec =
        Range
            { rangeMin = haskellAccessor field rec
            , rangeMax = haskellAccessor field rec
            }

-- | Retrieve the next 'Page' of data, if possible.
--
-- @since 0.1.1.0
nextPage
    ::
    ( ToFrom source select
    , E.I.I.SqlSelect select record
    , PersistQueryRead backend
    , PersistUniqueRead backend
    , BackendCompatible SqlBackend backend
    , BackendCompatible SqlBackend (BaseBackend backend)
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => source -> Page select record typ -> ReaderT backend m (Maybe (Page select record typ))
nextPage source Page{..}
    | pageRecordCount < unPageSize pageSize =
        pure Nothing
    | otherwise =
        getPage
            source
            pageFilters
            pageField
            pageSize
            pageSortOrder
            (bumpPageRange pageSortOrder pageDesiredRange pageRange)

-- | A @'Page' record typ@ describes a list of records and enough
-- information necessary to acquire the next page of records, if possible.
--
-- This is a distinct type from the 'Page' in "Database.Persist.Pagination"
-- because the 'pageFilters' field needs a different type. As a result,
-- some of this stuff is duplicated. It's possible that this can be fixed
-- and more code could be shared.
--
-- @since 0.1.1.0
data Page select record typ
    = Page
    { pageRecords      :: [record]
    -- ^ The collection of records.
    --
    -- @since 0.1.1.0
    , pageRecordCount  :: Int
    -- ^ The count of records in the collection. If this number is less
    -- than the 'pageSize' field, then a call to 'nextPage' will result in
    -- 'Nothing'.
    --
    -- @since 0.1.1.0
    , pageRange        :: Range typ
    -- ^ The minimum and maximum value of @typ@ in the list.
    --
    -- @since 0.1.1.0
    , pageDesiredRange :: DesiredRange typ
    -- ^ The desired range in the next page of values. When the
    -- 'pageSortOrder' is 'Ascending', then the 'rangeMin' value will
    -- increase with each page until the set of data is complete. Likewise,
    -- when the 'pageSortOrder' is 'Descending', then the 'rangeMax' will
    -- decrease until the final page is reached.
    --
    -- @since 0.1.1.0
    , pageField        :: SqlField select record typ
    -- ^ The field to sort on. This field should have an index on it, and
    -- ideally, the field should be monotonic - that is, you can only
    -- insert values at either extreme end of the range. A @created_at@
    -- timestamp or autogenerated ID work great for this. Non-monotonic
    -- keys can work too, but you may miss records that are inserted during
    -- a traversal.
    --
    -- @since 0.1.1.0
    , pageFilters      :: select -> SqlExpr (Value Bool)
    -- ^ The extra filters that are placed on the query.
    --
    -- @since 0.1.1.0
    , pageSize         :: PageSize
    -- ^ The desired size of the 'Page' for successive results.
    , pageSortOrder    :: SortOrder
    -- ^ Whether to sort on the 'pageField' in 'Ascending' or 'Descending'
    -- order. The choice you make here determines how the
    -- 'pageDesiredRange' changes with each page.
    --
    -- @since 0.1.1.0
    }

-- | An empty query value to pass to the functions when you don't have any
-- filters to run.
--
-- @since 0.1.1.0
emptyQuery :: select -> SqlExpr (Value Bool)
emptyQuery _ = val True

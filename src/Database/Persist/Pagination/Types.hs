{-# LANGUAGE DeriveFoldable      #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveTraversable   #-}

module Database.Persist.Pagination.Types where

import Control.Applicative (Alternative(..))
import           Database.Persist.Sql (Entity)

-- | The amount of records in a 'Page' of results.
--
-- @since 0.1.0.0
newtype PageSize = PageSize { unPageSize :: Int }
    deriving (Eq, Show)

-- | Whether to sort by @ASC@ or @DESC@ when you're paging over results.
--
-- @since 0.1.0.0
data SortOrder = Ascend | Descend
    deriving (Eq, Show)

-- | A datatype describing the min and max value of the relevant field that
-- you are ranging over in a non-empty sequence of records.
--
-- @since 0.1.0.0
data Range t = Range { rangeMin :: t, rangeMax :: t }
    deriving (Eq, Show, Functor, Foldable, Traversable)

instance Ord t => Semigroup (Range t) where
    Range l h <> Range l' h' = Range (min l l') (max h h')

instance (Bounded t, Ord t) => Monoid (Range t) where
    mempty = Range minBound maxBound
    mappend = (<>)

-- | Users aren't required to put a value in for the range - a value of
-- 'Nothing' is equivalent to saying "unbounded from below."
--
-- @since 0.1.0.0
type DesiredRange t = Range (Maybe t)

-- | Modify the 'DesiredRange' according to the 'Range' that was provided
-- by the query and the 'SortOrder'.
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

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
module Database.Esqueleto.PaginationSpec where

import           Conduit
import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import qualified Data.List                   as List
import qualified Data.Map                    as Map
import           Data.Maybe
import qualified Data.Set                    as Set
import           Data.Time
import           Database.Persist.Sqlite hiding ((==.))
import           Database.Persist.TH
import           Test.Hspec
import           Test.QuickCheck

import           Database.Esqueleto.Pagination
import           Database.Esqueleto (val, (==.), (^.))

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistUpperCase|

User
    name String
    age  Int
    createdAt UTCTime

    deriving Eq Ord Show
|]

spec :: Spec
spec = do
    it "streamEntities descend" $ do
        xs <- runDb $ do
            runConduit
                $ streamEntities
                    emptyQuery
                    UserCreatedAt
                    (PageSize 10)
                    Descend
                    (Range Nothing Nothing)
                .| sinkList
        let sortedKeys = List.sort (map entityKey xs)

        map length (List.group sortedKeys)
            `shouldBe`
                map length (map (:[]) sortedKeys)

    it "streamEntities ascend" $ do
        xs <- runDb $ do
            runConduit
                $ streamEntities
                    emptyQuery
                    UserCreatedAt
                    (PageSize 10)
                    Ascend
                    (Range Nothing Nothing)
                .| sinkList
        length xs `shouldBe` entityCount
        Set.toList (Set.fromList (map entityKey xs))
            `shouldBe`
                List.sort (map entityKey xs)

    it "getPage" $ do
        let pgSize = 10
        Just page <- runDb $ do
            getPage emptyQuery UserCreatedAt (PageSize pgSize) Ascend (Range Nothing Nothing :: DesiredRange UTCTime)
        let records1 = pageRecords page
        length records1
            `shouldBe`
                pgSize
        pageRecordCount page
            `shouldBe`
                pgSize
        let mmin = rangeMin (pageRange page)

        mpage2 <- runDb $ do
            nextPage page

        void mpage2 `shouldSatisfy` isJust

        let Just page2 = mpage2
            records2 = pageRecords page2

        length records2
            `shouldBe`
                pageRecordCount page2


        (Set.fromList records1 `Set.intersection` Set.fromList records2)
            `shouldBe` Set.empty

        (Set.fromList (map entityKey records1) `Set.intersection` Set.fromList (map entityKey records2))
            `shouldBe` Set.empty

    it "works for all pages" $ do
        pages <- runDb $ do
            Just page <-
                getPage emptyQuery UserCreatedAt (PageSize 10) Ascend (Range Nothing Nothing :: DesiredRange UTCTime)
            whileJust page nextPage
        let sortedKeys =
                List.sort (concatMap (map entityKey . pageRecords) pages)

        List.group sortedKeys `shouldBe` map pure sortedKeys

    it "works for id" $ do
        (records0, records1) <-
            runDb $
                (,) <$> do
                    runConduit
                        $ streamEntities
                            emptyQuery
                            UserId
                            (PageSize 10)
                            Ascend
                            (Range Nothing Nothing)
                        .| sinkList
                    <*> do
                        selectList [] []
        length (Set.fromList records0)
            `shouldBe`
                entityCount
        let mkMap = Map.fromList . map (\e -> (entityKey e, entityVal e))
            r0map = mkMap records0
            r1map = mkMap records1

        Map.keys r0map
            `shouldBe`
                Map.keys r1map

        void $ flip Map.traverseWithKey r0map $ \k a ->
            Map.lookup k r1map
                `shouldBe`
                    Just a

        void $ flip Map.traverseWithKey r1map $ \k a ->
            Map.lookup k r0map
                `shouldBe`
                    Just a

    it "works with a filter" $ do
        let searchAge = 1234
        usersWithSearchAge <-
            traverse
                (\k -> fmap k getCurrentTime)
                [User "foo" searchAge, User "bar" searchAge, User "baz" searchAge]
        irrelevantUsers <-
            traverse
                (\k -> fmap k getCurrentTime)
                [User "foo" 0, User "bar" 0, User "baz" 0, User "quux" 0]
        (returnedEntities, properUserIds) <-
            runDb $ do
                userIdsWithSearchAge <- insertMany usersWithSearchAge
                _ <- insertMany irrelevantUsers
                records <- runConduit
                    $ streamEntities
                        (\e -> e ^. UserAge ==. val searchAge)
                        UserCreatedAt
                        (PageSize 1)
                        Descend
                        (Range Nothing Nothing)
                    .| sinkList
                pure (records, userIdsWithSearchAge)

        length returnedEntities
            `shouldBe`
                length usersWithSearchAge

        forM_ returnedEntities $ \entity ->
            entity
                `shouldSatisfy`
                    ((searchAge ==) . userAge . entityVal)

        Set.fromList (map entityVal returnedEntities)
            `shouldBe`
                Set.fromList usersWithSearchAge

        Set.fromList (map entityKey returnedEntities)
            `shouldBe`
                Set.fromList properUserIds

whileJust :: Monad m => a -> (a -> m (Maybe a)) -> m [a]
whileJust a k = (a :) <$> do
    ma <- k a
    case ma of
        Nothing -> pure []
        Just a' -> whileJust a' k


runDb :: SqlPersistM a -> IO a
runDb action = do
    runSqlite ":memory:" $ do
        runMigration migrateAll
        seedDatabase
        action

entityCount :: Int
entityCount = 63

seedDatabase :: SqlPersistM ()
seedDatabase = do
    let now = UTCTime (fromGregorian 1990 1 1) 0
    forM_ [1..entityCount] $ \n -> do
        str <- liftIO $ generate $ do
            i <- choose (5, 20)
            vectorOf i arbitrary
        insert $ User str n ((50 * fromIntegral n) `addUTCTime` now)

typeChecksWithSqlReadT
    :: MonadIO m
    => ConduitT Void (Entity User) (ReaderT SqlReadBackend m) ()
typeChecksWithSqlReadT =
    streamEntities
        emptyQuery
        UserCreatedAt
        (PageSize 10)
        Descend
        (Range Nothing Nothing)

typeChecksWithSqlWriteT
    :: MonadIO m
    => ConduitT Void (Entity User) (ReaderT SqlWriteBackend m) ()
typeChecksWithSqlWriteT =
    streamEntities
        emptyQuery
        UserCreatedAt
        (PageSize 10)
        Descend
        (Range Nothing Nothing)

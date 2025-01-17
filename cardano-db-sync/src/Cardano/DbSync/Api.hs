{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts #-}

module Cardano.DbSync.Api (
  fullInsertOptions,
  defaultInsertOptions,
  turboInsertOptions,
  setConsistentLevel,
  getConsistentLevel,
  isConsistent,
  noneFixed,
  isDataFixed,
  getIsSyncFixed,
  setIsFixed,
  setIsFixedAndMigrate,
  getRanIndexes,
  runIndexMigrations,
  runExtraMigrationsMaybe,
  getSafeBlockNoDiff,
  getPruneInterval,
  whenConsumeTxOut,
  whenPruneTxOut,
  getHasConsumed,
  getPrunes,
  mkSyncEnvFromConfig,
  replaceConnection,
  verifySnapshotPoint,
  getBackend,
  getInsertOptions,
  getTrace,
  getTopLevelConfig,
  getNetwork,
  hasLedgerState,
  getLatestPoints,
  getSlotHash,
  getDbLatestBlockInfo,
  getDbTipBlockNo,
  getCurrentTipBlockNo,
  generateNewEpochEvents,
  logDbState,
  convertToPoint,
) where

import Cardano.BM.Trace (Trace, logInfo, logWarning)
import qualified Cardano.Chain.Genesis as Byron
import Cardano.Crypto.ProtocolMagic (ProtocolMagicId (..))
import qualified Cardano.Db as DB
import Cardano.DbSync.Api.Types
import Cardano.DbSync.Cache
import Cardano.DbSync.Config.Cardano
import Cardano.DbSync.Config.Shelley
import Cardano.DbSync.Config.Types
import Cardano.DbSync.Error
import Cardano.DbSync.Ledger.State (HasLedgerEnv (..), LedgerEvent (..), LedgerStateFile (..), SnapshotPoint (..), getHeaderHash, hashToAnnotation, listKnownSnapshots, mkHasLedgerEnv)
import Cardano.DbSync.LocalStateQuery
import Cardano.DbSync.Types
import Cardano.DbSync.Util
import qualified Cardano.Ledger.BaseTypes as Ledger
import qualified Cardano.Ledger.Shelley.Genesis as Shelley
import Cardano.Prelude
import Cardano.Slotting.Slot (EpochNo (..), SlotNo (..), WithOrigin (..))
import Control.Concurrent.Class.MonadSTM.Strict (
  newTBQueueIO,
  newTVarIO,
  readTVar,
  readTVarIO,
  writeTVar,
 )
import Control.Monad.Trans.Maybe (MaybeT (..))
import qualified Data.Strict.Maybe as Strict
import Data.Time.Clock (getCurrentTime)
import Database.Persist.Postgresql (ConnectionString)
import Database.Persist.Sql (SqlBackend)
import Ouroboros.Consensus.Block.Abstract (HeaderHash, Point (..), fromRawHash, BlockProtocol)
import Ouroboros.Consensus.BlockchainTime.WallClock.Types (SystemStart (..))
import Ouroboros.Consensus.Config (TopLevelConfig, SecurityParam (..), configSecurityParam)
import Ouroboros.Consensus.Node.ProtocolInfo (ProtocolInfo (pInfoConfig))
import qualified Ouroboros.Consensus.Node.ProtocolInfo as Consensus
import Ouroboros.Network.Block (BlockNo (..), Point (..))
import Ouroboros.Network.Magic (NetworkMagic (..))
import qualified Ouroboros.Network.Point as Point
import Ouroboros.Consensus.Protocol.Abstract (ConsensusProtocol)

setConsistentLevel :: SyncEnv -> ConsistentLevel -> IO ()
setConsistentLevel env cst = do
  logInfo (getTrace env) $ "Setting ConsistencyLevel to " <> textShow cst
  atomically $ writeTVar (envConsistentLevel env) cst

getConsistentLevel :: SyncEnv -> IO ConsistentLevel
getConsistentLevel env =
  readTVarIO (envConsistentLevel env)

isConsistent :: SyncEnv -> IO Bool
isConsistent env = do
  cst <- getConsistentLevel env
  case cst of
    Consistent -> pure True
    _ -> pure False

noneFixed :: FixesRan -> Bool
noneFixed NoneFixRan = True
noneFixed _ = False

isDataFixed :: FixesRan -> Bool
isDataFixed DataFixRan = True
isDataFixed _ = False

getIsSyncFixed :: SyncEnv -> IO FixesRan
getIsSyncFixed = readTVarIO . envIsFixed

setIsFixed :: SyncEnv -> FixesRan -> IO ()
setIsFixed env fr = do
  atomically $ writeTVar (envIsFixed env) fr

setIsFixedAndMigrate :: SyncEnv -> FixesRan -> IO ()
setIsFixedAndMigrate env fr = do
  envRunDelayedMigration env DB.Fix
  atomically $ writeTVar (envIsFixed env) fr

getRanIndexes :: SyncEnv -> IO Bool
getRanIndexes env = do
  readTVarIO $ envIndexes env

runIndexMigrations :: SyncEnv -> IO ()
runIndexMigrations env = do
  haveRan <- readTVarIO $ envIndexes env
  unless haveRan $ do
    envRunDelayedMigration env DB.Indexes
    logInfo (getTrace env) "Indexes were created"
    atomically $ writeTVar (envIndexes env) True

initExtraMigrations :: Bool -> Bool -> ExtraMigrations
initExtraMigrations cons prne =
  ExtraMigrations
    { emRan = False
    , emConsume = cons || prne
    , emPrune = prne
    }

runExtraMigrationsMaybe :: SyncEnv -> IO ()
runExtraMigrationsMaybe env = do
  extraMigr <- liftIO $ readTVarIO $ envExtraMigrations env
  logInfo (getTrace env) $ textShow extraMigr
  unless (emRan extraMigr) $ do
    backend <- getBackend env
    DB.runDbIohkNoLogging backend $
      DB.runExtraMigrations
        (getTrace env)
        (getSafeBlockNoDiff env)
        (emConsume extraMigr)
        (emPrune extraMigr)
  liftIO $ atomically $ writeTVar (envExtraMigrations env) (extraMigr {emRan = True})

getSafeBlockNoDiff :: SyncEnv -> Word64
getSafeBlockNoDiff syncEnv = 2 * getSecurityParam syncEnv

getPruneInterval :: SyncEnv -> Word64
getPruneInterval syncEnv = 10 * getSecurityParam syncEnv

whenConsumeTxOut :: MonadIO m => SyncEnv -> m () -> m ()
whenConsumeTxOut env action = do
  extraMigr <- liftIO $ readTVarIO $ envExtraMigrations env
  when (emConsume extraMigr) action

whenPruneTxOut :: MonadIO m => SyncEnv -> m () -> m ()
whenPruneTxOut env action = do
  extraMigr <- liftIO $ readTVarIO $ envExtraMigrations env
  when (emPrune extraMigr) action

getHasConsumed :: SyncEnv -> IO Bool
getHasConsumed env = do
  extraMigr <- liftIO $ readTVarIO $ envExtraMigrations env
  pure $ emConsume extraMigr

getPrunes :: SyncEnv -> IO Bool
getPrunes env = do
  extraMigr <- liftIO $ readTVarIO $ envExtraMigrations env
  pure $ emPrune extraMigr

fullInsertOptions :: InsertOptions
fullInsertOptions = InsertOptions True True True True

defaultInsertOptions :: InsertOptions
defaultInsertOptions = fullInsertOptions

turboInsertOptions :: InsertOptions
turboInsertOptions = InsertOptions False False False False

replaceConnection :: SyncEnv -> SqlBackend -> IO ()
replaceConnection env sqlBackend = do
  atomically $ writeTVar (envBackend env) $ Strict.Just sqlBackend

initEpochState :: EpochState
initEpochState =
  EpochState
    { esInitialized = False
    , esEpochNo = Strict.Nothing
    }

generateNewEpochEvents :: SyncEnv -> SlotDetails -> STM [LedgerEvent]
generateNewEpochEvents env details = do
  !oldEpochState <- readTVar (envEpochState env)
  writeTVar (envEpochState env) newEpochState
  pure $ maybeToList (newEpochEvent oldEpochState)
  where
    currentEpochNo :: EpochNo
    currentEpochNo = sdEpochNo details

    newEpochEvent :: EpochState -> Maybe LedgerEvent
    newEpochEvent oldEpochState =
      case esEpochNo oldEpochState of
        Strict.Nothing -> Just $ LedgerStartAtEpoch currentEpochNo
        Strict.Just oldEpoch ->
          if currentEpochNo == 1 + oldEpoch
            then Just $ LedgerNewEpoch currentEpochNo (getSyncStatus details)
            else Nothing

    newEpochState :: EpochState
    newEpochState =
      EpochState
        { esInitialized = True
        , esEpochNo = Strict.Just currentEpochNo
        }

getTopLevelConfig :: SyncEnv -> TopLevelConfig CardanoBlock
getTopLevelConfig syncEnv =
  case envLedgerEnv syncEnv of
    HasLedger hasLedgerEnv -> Consensus.pInfoConfig $ leProtocolInfo hasLedgerEnv
    NoLedger noLedgerEnv -> Consensus.pInfoConfig $ nleProtocolInfo noLedgerEnv

getTrace :: SyncEnv -> Trace IO Text
getTrace sEnv =
  case envLedgerEnv sEnv of
    HasLedger hasLedgerEnv -> leTrace hasLedgerEnv
    NoLedger noLedgerEnv -> nleTracer noLedgerEnv

getNetwork :: SyncEnv -> Ledger.Network
getNetwork sEnv =
  case envLedgerEnv sEnv of
    HasLedger hasLedgerEnv -> leNetwork hasLedgerEnv
    NoLedger noLedgerEnv -> nleNetwork noLedgerEnv

getInsertOptions :: SyncEnv -> InsertOptions
getInsertOptions = soptInsertOptions . envOptions

getSlotHash :: SqlBackend -> SlotNo -> IO [(SlotNo, ByteString)]
getSlotHash backend = DB.runDbIohkNoLogging backend . DB.querySlotHash

getBackend :: SyncEnv -> IO SqlBackend
getBackend env = do
  mBackend <- readTVarIO $ envBackend env
  case mBackend of
    Strict.Just conn -> pure conn
    Strict.Nothing -> panic "sql connection not initiated"

hasLedgerState :: SyncEnv -> Bool
hasLedgerState syncEnv =
  case envLedgerEnv syncEnv of
    HasLedger _ -> True
    NoLedger _ -> False

getDbLatestBlockInfo :: SqlBackend -> IO (Maybe TipInfo)
getDbLatestBlockInfo backend = do
  runMaybeT $ do
    block <- MaybeT $ DB.runDbIohkNoLogging backend DB.queryLatestBlock
    -- The EpochNo, SlotNo and BlockNo can only be zero for the Byron
    -- era, but we need to make the types match, hence `fromMaybe`.
    pure $
      TipInfo
        { bHash = DB.blockHash block
        , bEpochNo = EpochNo . fromMaybe 0 $ DB.blockEpochNo block
        , bSlotNo = SlotNo . fromMaybe 0 $ DB.blockSlotNo block
        , bBlockNo = BlockNo . fromMaybe 0 $ DB.blockBlockNo block
        }

getDbTipBlockNo :: SyncEnv -> IO (Point.WithOrigin BlockNo)
getDbTipBlockNo env =
  getBackend env
    >>= getDbLatestBlockInfo
    <&> maybe Point.Origin (Point.At . bBlockNo)

logDbState :: SyncEnv -> IO ()
logDbState env = do
  backend <- getBackend env
  mblk <- getDbLatestBlockInfo backend
  case mblk of
    Nothing -> logInfo tracer "Cardano.Db is empty"
    Just tip -> logInfo tracer $ mconcat ["Cardano.Db tip is at ", showTip tip]
  where
    showTip :: TipInfo -> Text
    showTip tipInfo =
      mconcat
        [ "slot "
        , DB.textShow (unSlotNo $ bSlotNo tipInfo)
        , ", block "
        , DB.textShow (unBlockNo $ bBlockNo tipInfo)
        ]

    tracer :: Trace IO Text
    tracer = getTrace env

getCurrentTipBlockNo :: SyncEnv -> IO (WithOrigin BlockNo)
getCurrentTipBlockNo env = do
  backend <- getBackend env
  maybeTip <- getDbLatestBlockInfo backend
  case maybeTip of
    Just tip -> pure $ At (bBlockNo tip)
    Nothing -> pure Origin

mkSyncEnv ::
  Trace IO Text ->
  ConnectionString ->
  SyncOptions ->
  ProtocolInfo IO CardanoBlock ->
  Ledger.Network ->
  NetworkMagic ->
  SystemStart ->
  SyncNodeParams ->
  Bool ->
  RunMigration ->
  IO SyncEnv
mkSyncEnv trce connString syncOptions protoInfo nw nwMagic systemStart syncNodeParams ranMigrations runMigrationFnc = do
  cache <- if soptCache syncOptions then newEmptyCache 250000 50000 else pure uninitiatedCache
  backendVar <- newTVarIO Strict.Nothing
  consistentLevelVar <- newTVarIO Unchecked
  fixDataVar <- newTVarIO $ if ranMigrations then DataFixRan else NoneFixRan
  indexesVar <- newTVarIO $ enpForceIndexes syncNodeParams
  extraMigrVar <- newTVarIO $ initExtraMigrations (enpMigrateConsumed syncNodeParams) (enpPruneTxOut syncNodeParams)
  owq <- newTBQueueIO 100
  orq <- newTBQueueIO 100
  epochVar <- newTVarIO initEpochState
  epochSyncTime <- newTVarIO =<< getCurrentTime
  ledgerEnvType <-
    case (enpMaybeLedgerStateDir syncNodeParams, enpShouldUseLedger syncNodeParams) of
      (Just dir, True) ->
        HasLedger
          <$> mkHasLedgerEnv
            trce
            protoInfo
            dir
            nw
            systemStart
            syncOptions
      (Nothing, False) -> NoLedger <$> mkNoLedgerEnv trce protoInfo nw systemStart
      (Just _, False) -> do
        logWarning trce $
          "Using `--disable-ledger` doesn't require having a --state-dir."
            <> " For more details view https://github.com/input-output-hk/cardano-db-sync/blob/master/doc/configuration.md#--disable-ledger"
        NoLedger <$> mkNoLedgerEnv trce protoInfo nw systemStart
      -- This won't ever call because we error out this combination at parse time
      (Nothing, True) -> NoLedger <$> mkNoLedgerEnv trce protoInfo nw systemStart

  pure $
    SyncEnv
      { envProtocol = SyncProtocolCardano
      , envNetworkMagic = nwMagic
      , envSystemStart = systemStart
      , envConnString = connString
      , envRunDelayedMigration = runMigrationFnc
      , envBackend = backendVar
      , envOptions = syncOptions
      , envConsistentLevel = consistentLevelVar
      , envIsFixed = fixDataVar
      , envIndexes = indexesVar
      , envCache = cache
      , envExtraMigrations = extraMigrVar
      , envOfflineWorkQueue = owq
      , envOfflineResultQueue = orq
      , envEpochState = epochVar
      , envEpochSyncTime = epochSyncTime
      , envLedgerEnv = ledgerEnvType
      }

mkSyncEnvFromConfig ::
  Trace IO Text ->
  ConnectionString ->
  SyncOptions ->
  GenesisConfig ->
  SyncNodeParams ->
  -- | migrations were ran on startup
  Bool ->
  -- | run migration function
  RunMigration ->
  IO (Either SyncNodeError SyncEnv)
mkSyncEnvFromConfig trce connString syncOptions genCfg syncNodeParams ranMigration runMigrationFnc =
  case genCfg of
    GenesisCardano _ bCfg sCfg _
      | unProtocolMagicId (Byron.configProtocolMagicId bCfg) /= Shelley.sgNetworkMagic (scConfig sCfg) ->
          pure . Left . NECardanoConfig $
            mconcat
              [ "ProtocolMagicId "
              , DB.textShow (unProtocolMagicId $ Byron.configProtocolMagicId bCfg)
              , " /= "
              , DB.textShow (Shelley.sgNetworkMagic $ scConfig sCfg)
              ]
      | Byron.gdStartTime (Byron.configGenesisData bCfg) /= Shelley.sgSystemStart (scConfig sCfg) ->
          pure . Left . NECardanoConfig $
            mconcat
              [ "SystemStart "
              , DB.textShow (Byron.gdStartTime $ Byron.configGenesisData bCfg)
              , " /= "
              , DB.textShow (Shelley.sgSystemStart $ scConfig sCfg)
              ]
      | otherwise ->
          Right
            <$> mkSyncEnv
              trce
              connString
              syncOptions
              (mkProtocolInfoCardano genCfg [])
              (Shelley.sgNetworkId $ scConfig sCfg)
              (NetworkMagic . unProtocolMagicId $ Byron.configProtocolMagicId bCfg)
              (SystemStart . Byron.gdStartTime $ Byron.configGenesisData bCfg)
              syncNodeParams
              ranMigration
              runMigrationFnc

-- | 'True' is for in memory points and 'False' for on disk
getLatestPoints :: SyncEnv -> IO [(CardanoPoint, Bool)]
getLatestPoints env = do
  case envLedgerEnv env of
    HasLedger hasLedgerEnv -> do
      snapshotPoints <- listKnownSnapshots hasLedgerEnv
      verifySnapshotPoint env snapshotPoints
    NoLedger _ -> do
      -- Brings the 5 latest.
      dbBackend <- getBackend env
      lastPoints <- DB.runDbIohkNoLogging dbBackend DB.queryLatestPoints
      pure $ mapMaybe convert lastPoints
  where
    convert (Nothing, _) = Nothing
    convert (Just slot, bs) = convertToDiskPoint (SlotNo slot) bs

verifySnapshotPoint :: SyncEnv -> [SnapshotPoint] -> IO [(CardanoPoint, Bool)]
verifySnapshotPoint env snapPoints =
  catMaybes <$> mapM validLedgerFileToPoint snapPoints
  where
    validLedgerFileToPoint :: SnapshotPoint -> IO (Maybe (CardanoPoint, Bool))
    validLedgerFileToPoint (OnDisk lsf) = do
      backend <- getBackend env
      hashes <- getSlotHash backend (lsfSlotNo lsf)
      let valid = find (\(_, h) -> lsfHash lsf == hashToAnnotation h) hashes
      case valid of
        Just (slot, hash) | slot == lsfSlotNo lsf -> pure $ convertToDiskPoint slot hash
        _ -> pure Nothing
    validLedgerFileToPoint (InMemory pnt) = do
      case pnt of
        GenesisPoint -> pure Nothing
        BlockPoint slotNo hsh -> do
          backend <- getBackend env
          hashes <- getSlotHash backend slotNo
          let valid = find (\(_, dbHash) -> getHeaderHash hsh == dbHash) hashes
          case valid of
            Just (dbSlotNo, _) | slotNo == dbSlotNo -> pure $ Just (pnt, True)
            _ -> pure Nothing

convertToDiskPoint :: SlotNo -> ByteString -> Maybe (CardanoPoint, Bool)
convertToDiskPoint slot hashBlob = (,False) <$> convertToPoint slot hashBlob

convertToPoint :: SlotNo -> ByteString -> Maybe CardanoPoint
convertToPoint slot hashBlob =
  Point . Point.block slot <$> convertHashBlob hashBlob
  where
    convertHashBlob :: ByteString -> Maybe (HeaderHash CardanoBlock)
    convertHashBlob = Just . fromRawHash (Proxy @CardanoBlock)

getSecurityParam :: SyncEnv -> Word64
getSecurityParam syncEnv =
  case envLedgerEnv syncEnv of
    HasLedger hle -> getMaxRollbacks $ leProtocolInfo hle
    NoLedger nle -> getMaxRollbacks $ nleProtocolInfo nle

getMaxRollbacks ::
  ConsensusProtocol (BlockProtocol blk) =>
  ProtocolInfo IO blk ->
  Word64
getMaxRollbacks = maxRollbacks . configSecurityParam . pInfoConfig

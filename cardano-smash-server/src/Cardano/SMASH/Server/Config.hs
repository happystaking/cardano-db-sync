{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.SMASH.Server.Config where

import           Cardano.Prelude

import           Data.Aeson
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Yaml as Yaml

import qualified Cardano.BM.Configuration.Model as Logging
import qualified Cardano.BM.Setup as Logging
import           Cardano.BM.Trace (Trace)
import           Cardano.Db (textShow)

import           System.IO.Error

data SmashServerParams = SmashServerParams
  { sspSmashPort :: !Int
  , sspConfigFile :: !FilePath -- config is only used for the logging parameters.
  , sspAdminUsers :: !(Maybe FilePath)
  }

defaultSmashPort :: Int
defaultSmashPort = 3100

paramsToConfig :: SmashServerParams -> IO SmashServerConfig
paramsToConfig params = do
  appUsers <- readAppUsers $ sspAdminUsers params
  tracer <- configureLogging (sspConfigFile params) "smash-server"
  pure $ SmashServerConfig
    { sscSmashPort = sspSmashPort params
    , sscTrace = tracer
    , sscAdmins = appUsers
    }

data SmashServerConfig = SmashServerConfig
  { sscSmashPort :: Int
  , sscTrace :: Trace IO Text
  , sscAdmins :: ApplicationUsers
  }

-- A data type we use to store user credentials.
data ApplicationUser = ApplicationUser
    { username :: !Text
    , password :: !Text
    } deriving (Eq, Show, Generic)

instance ToJSON ApplicationUser
instance FromJSON ApplicationUser

-- A list of users with special rights.
newtype ApplicationUsers = ApplicationUsers [ApplicationUser]
    deriving (Eq, Show, Generic)

instance ToJSON ApplicationUsers
instance FromJSON ApplicationUsers

readAppUsers :: Maybe FilePath -> IO ApplicationUsers
readAppUsers mPath = case mPath of
  Nothing -> pure $ ApplicationUsers []
  Just path -> do
    userLines <- Text.lines <$> Text.readFile path
    let nonEmptyLines = filter (not . Text.null) userLines
    case mapM parseAppUser nonEmptyLines of
      Right users -> pure $ ApplicationUsers users
      Left err -> throwIO $ userError $ Text.unpack err

parseAppUser :: Text -> Either Text ApplicationUser
parseAppUser line = case Text.breakOn "," line of
    (user, commaPswd)
      | not (Text.null commaPswd)
      , passwd <- Text.tail commaPswd -- strip the comma
      -> Right $ ApplicationUser (prepareCred user) (prepareCred passwd)
    _ -> Left "Credentials need to be supplied in the form: username,password"
  where
    prepareCred name = Text.strip name

configureLogging :: FilePath -> Text -> IO (Trace IO Text)
configureLogging fp loggingName = do
  bs <- readByteString fp "DbSync" -- only uses the db-sync config
  case Yaml.decodeEither' bs of
    Left err -> panic $ "readSyncNodeConfig: Error parsing config: " <> textShow err
    Right representation -> do
      -- Logging.Configuration
      logConfig <- Logging.setupFromRepresentation representation
      liftIO $ Logging.setupTrace (Right logConfig) loggingName

readByteString :: FilePath -> Text -> IO ByteString
readByteString fp cfgType =
  catch (BS.readFile fp) $ \(_ :: IOException) ->
    panic $ mconcat [ "Cannot find the ", cfgType, " configuration file at : ", Text.pack fp ]
{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings, RecordWildCards #-}

module Upcast.Environment where

import System.Directory (canonicalizePath)
import System.Posix.Env (getEnvDefault, getEnv)
import System.FilePath.Posix

import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Map as Map

import Data.Aeson (decodeStrict)

import Upcast.Monad
import Upcast.IO
import Upcast.Types
import Upcast.Temp
import Upcast.Command
import Upcast.DeployCommands (setupAgentF, sshAddKeyFile)

import Paths_upcast

sequenceMaybe :: Monad m => [m (Maybe a)] -> m (Maybe a)
sequenceMaybe [] = return Nothing
sequenceMaybe (act:actions) = act >>= maybe (sequenceMaybe actions) (return . Just)

nixPath :: IO (Maybe String)
nixPath = sequenceMaybe [getEnv "NIX_UPCAST", Just <$> getDataFileName "nix"]

readEnvContext :: IO EnvContext
readEnvContext = do
    nixArgs <- T.pack <$> getEnvDefault "UPCAST_NIX_FLAGS" ""
    nixSSHClosureCache <- getEnv "UPCAST_SSH_CLOSURE_CACHE"
    Just upcastNix <- fmap T.pack <$> nixPath
    sshAuthSock <- T.pack <$> getEnvDefault "SSH_AUTH_SOCK" "/dev/null"
    unattended <- getEnv "UPCAST_UNATTENDED"
    let deployMode = maybe Default (const Unattended) unattended
    return EnvContext{..}

context :: String -> IO DeployContext
context file = do
    expressionFile <- canonicalizePath file

    closuresPath <- randomTempFileName "machines."
    subs <- getEnv "UPCAST_CLOSURES"
    envContext <- readEnvContext

    let uuid = "new-upcast-deployment"
        stateFile = replaceExtension expressionFile "store"
        closureSubstitutes = maybe Map.empty id $ join $ decodeStrict . BS.pack <$> subs

    return DeployContext{..}

ctxAuth :: DeployContext -> [Text] -> IO DeployContext
ctxAuth ctx keyFiles = do
    userAuthSock <- getEnv "UPCAST_SSH_AUTH_SOCK"
    agentSocket <- case userAuthSock of
                     Just sock -> do
                        warn ["Using UPCAST_SSH_AUTH_SOCK: ", sock]
                        return sock
                     Nothing | null keyFiles ->  fallback
                             | otherwise -> setupAgentF sshAddKeyFile keyFiles

    return ctx { envContext = (envContext ctx){ sshAuthSock = T.pack agentSocket } }
  where
    fallback = do
      sock <- getEnvDefault "SSH_AUTH_SOCK" ""
      warn [ "None of instances reference ssh key files, using SSH_AUTH_SOCK ("
           , show sock, ")."]
      when (null sock) $
        fail "SSH_AUTH_SOCK is not set, please setup your ssh agent with necessary keys."
      return sock


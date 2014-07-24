{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings, RecordWildCards #-}

module Main where

import Control.Monad (join)
import Control.Applicative
import Options.Applicative

import System.Directory (canonicalizePath)
import System.FilePath.Posix
import System.Posix.Files (readSymbolicLink)
import System.Posix.Env (getEnvDefault, getEnv)

import Data.List (intercalate)
import qualified Data.Text as T
import Data.Text (Text(..))
import Data.ByteString.Char8 (split)
import Data.Default

import Upcast.Interpolate (nl)
import Upcast.Nix
import Upcast.Aws
import Upcast.Types
import Upcast.Resource
import Upcast.Deploy
import Upcast.DeployCommands
import Upcast.Command
import Upcast.Temp
import qualified Upcast.Nixops as Legacy
import Paths_upcast

context :: String -> [String] -> IO DeployContext
context file args = do
    path <- canonicalizePath file
    let ctx = def { expressionFile = T.pack path
                  , stateFile = replaceExtension path "store"
                  }
    nix <- T.pack <$> getDataFileName "nix"
    machinesPath <- randomTempFileName "machines."
    env <- getEnvDefault "UPCAST_NIX_FLAGS" ""
    let ctx' = ctx { upcastNix = nix
                   , nixArgs = T.concat [T.pack $ intercalate " " args, " ", T.pack env]
                   , closuresPath = machinesPath
                   }
    return ctx'

install DeployContext{..} machines = do
    closures <- mapM (fmap (split '\n') . fgconsume . nixClosure . closurePath) machines
    sysEnv <- mapM (readSymbolicLink . closurePath) machines
    let margs = zip (fmap remote machines) sysEnv
    mapM_ fgrun $ commands margs closures
  where
    closurePath Machine{..} = closuresPath </> (T.unpack m_hostname)
    remote Machine{..} = Remote (T.unpack m_keyFile) (T.unpack m_publicIp)

    clargs (cls, m) = (remote m, cls)

    commands margs cls = concat [ fmap (ssh' sshAuthSock . uncurry nixTrySubstitutes . clargs) $ zip cls machines
                                , fmap (uncurry (nixCopyClosureTo sshAuthSock)) margs
                                , fmap (ssh' sshAuthSock . uncurry nixSetProfile) margs
                                , fmap (ssh' sshAuthSock . nixSwitchToConfiguration) $ fmap remote machines
                                ]

resources ctx = do
    Right info <- deploymentInfo ctx
    machines <- evalResources ctx info
    return machines

deploy ctx@DeployContext{..} = do
    machines <- resources ctx
    let machineNames = fmap (T.unpack . m_hostname) machines
    ctx' <- ctxAuth $ fmap m_keyFile machines
    let build = nixBuildMachines ctx' (T.unpack expressionFile) uuid machineNames closuresPath
    fgrun build
    install ctx' machines
  where
    ctxAuth keyFiles = do
      userAuthSock <- getEnv "UPCAST_SSH_AUTH_SOCK"
      agentSocket <- case userAuthSock of
                       Just sock -> return sock
                       Nothing -> setupAgentF sshAddKeyFile keyFiles
      return ctx { sshAuthSock = T.pack agentSocket }

infoOnly file args = do
    Right info <- context file args >>= deploymentInfo
    pprint info

debug file args = do
    ctx@DeployContext{..} <- context file args
    Right info <- deploymentInfo ctx
    machines <- debugEvalResources ctx info
    let machineNames = fmap (T.unpack . m_hostname) machines
    let build = nixBuildMachines ctx (T.unpack expressionFile) uuid machineNames closuresPath
    fgrun build
    return ()

go file args = do
    ctx@DeployContext{..} <- context file args
    deploy ctx

sshConfig file args = context file args >>= resources >>= putStrLn . intercalate "\n" . fmap config
  where
    config Machine{..} = [nl|
Host #{m_hostname}
    HostName #{m_publicIp}
    User root
    IdentityFile #{m_keyFile}
    ControlMaster auto
    ControlPath ~/.ssh/master-%r@%h:%p
    ForwardAgent yes
    ControlPersist 60s
|]


main = join $ customExecParser prefs opts
  where
    prefs = ParserPrefs { prefMultiSuffix = ""
                        , prefDisambiguate = True
                        , prefShowHelpOnError = True
                        , prefBacktrack = True
                        , prefColumns = 80
                        }

    opts = parser `info` header "upcast - infrastructure orchestratrion"

    parser = subparser (command "go" (args go `info` progDesc "execute deployment") <>
                        command "build" (args debug `info` progDesc "dry-run resource stage and perform a build") <>
                        command "info" (args infoOnly `info` progDesc "print deployment resource information in json format") <>
                        command "ssh-config" (args sshConfig `info` progDesc "print ssh config for deployment (evaluates resources)")
                        )

    args comm = comm <$> argument str exp <*> many (argument str nixArgs)
    exp = metavar "<expression>"
    nixArgs = metavar "nix arguments..."


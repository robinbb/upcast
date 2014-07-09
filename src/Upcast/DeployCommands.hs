{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings, RecordWildCards #-}

module Upcast.DeployCommands where

import Data.Text (Text)

import Upcast.Interpolate (n)

import Upcast.Nix
import Upcast.Deploy
import Upcast.Command
import Upcast.State

nixBaseOptions DeployContext{..} = [n|
                 -I #{nixPath}
                 -I nixops=#{nixops}
                 --option use-binary-cache true
                 --option binary-caches http://hydra.nixos.org
                 --option use-ssh-substituter true
                 --option ssh-substituter-hosts me@node1.example.com
                 --show-trace
                 |]

sshAgent socket = Cmd Local [n|ssh-agent -a #{socket}|]
sshAddKey socket key = Cmd Local [n|echo '#{key}' | env SSH_AUTH_SOCK=#{socket} SSH_ASKPASS=/usr/bin/true ssh-add -|]
sshListKeys socket = Cmd Local [n|env SSH_AUTH_SOCK=#{socket} ssh-add -l|]

nixCopyClosureTo sshAuthSock (Remote _ host) path =
    Cmd Local [n|env SSH_AUTH_SOCK=#{sshAuthSock} nix-copy-closure --to root@#{host} #{path} --gzip|]

nixCopyClosureToFast controlPath (Remote key host) path =
    Cmd Local [n|env NIX_SSHOPTS="-i #{key} -S #{controlPath}" nix-copy-closure --to root@#{host} #{path} --gzip|]

nixDeploymentInfo ctx exprs uuid = Cmd Local [n|
                     nix-instantiate #{nixBaseOptions ctx}
                     --arg networkExprs '#{listToNix exprs}'
                     --arg args {}
                     --argstr uuid #{uuid}
                     '<nixops/eval-deployment.nix>'
                     --eval-only --strict --read-write-mode
                     --arg checkConfigurationOptions false
                     -A info
                     |]

nixBuildMachines ctx exprs uuid names outputPath = Cmd Local [n|
                   env NIX_BUILD_HOOK="$HOME/.nix-profile/libexec/nix/build-remote.pl"
                   NIX_REMOTE_SYSTEMS="$HOME/remote-systems.conf"
                   NIX_CURRENT_LOAD="/tmp/load2"
                   TEST=1
                   nix-build #{nixBaseOptions ctx}
                   --arg networkExprs '#{listToNix exprs}'
                   --arg args {}
                   --argstr uuid #{uuid}
                   --arg names '#{listToNix names}'
                   '<nixops/eval-deployment.nix>'
                   -A machines
                   -o #{outputPath}
                   |]

nixSetProfile remote closure = Cmd remote [n|
                                  nix-env -p /nix/var/nix/profiles/system --set "#{closure}"
                                  |]

nixSwitchToConfiguration remote = Cmd remote [n|
                                  env NIXOS_NO_SYNC=1 /nix/var/nix/profiles/system/bin/switch-to-configuration switch
                                  |]

-- nixTrySubstitutes remote closure =
               -- closure = subprocess_check_output(["nix-store", "-qR", path]).splitlines()
               -- self.run_command("nix-store -j 4 -r --ignore-unknown " + ' '.join(closure), check=False)


ssh' :: Text -> Command Remote -> Command Local
ssh' sshAuthSock (Cmd (Remote _ host) cmd) =
    Cmd Local [n|env SSH_AUTH_SOCK=#{sshAuthSock} ssh -x root@#{host} -- '#{cmd}'|]

deploymentInfo ctx (State deployment _ exprs _) =
    let info = nixDeploymentInfo ctx (exprs) (deploymentUuid deployment)
        in do
          i <- fgconsume info
          return $ nixValue i

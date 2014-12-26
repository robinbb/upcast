{ config, pkgs, name, lib ? pkgs.lib, ... }:

with lib;

let inherit (import ./lib.nix { inherit lib; }) union infra; in

{

  options = {

    region = mkOption {
      type = types.str;
      description = "Amazon EC2 region.";
    };

    accessKeyId = mkOption {
      default = "";
      type = types.str;
      description = "The AWS Access Key ID.";
    };

    cidrBlock = mkOption {
      type = types.str;
      default = name;
    };

  };

  config._type = "ec2-vpc";

}

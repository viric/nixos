{ config, pkgs, ... }:

with pkgs.lib;

let

  inStage1 = any (fs: fs == "btrfs") config.boot.initrd.supportedFilesystems;
  inStage2 = any (fs: fs == "btrfs") config.boot.supportedFilesystems;

in

{
  config = mkIf (any (fs: fs == "btrfs") config.boot.supportedFilesystems) {

    system.fsPackages = [ pkgs.btrfsProgs ];

    boot.initrd.kernelModules = mkIf inStage1 [ "btrfs" "crc32c" ];

    # This way the module
    boot.kernelModules = mkIf inStage2 [ "btrfs" "crc32c" ];

    boot.initrd.extraUtilsCommands = mkIf inStage1
      ''
        cp -v ${pkgs.btrfsProgs}/bin/btrfsck $out/bin
        cp -v ${pkgs.btrfsProgs}/bin/btrfs $out/bin
        ln -sv btrfsck $out/bin/fsck.btrfs
      '';

    boot.initrd.postDeviceCommands = mkIf inStage1
      ''
        btrfs device scan
      '';

    services.udev.extraRules = ''
        ACTION=="add|change", SUBSYSTEM=="block", RUN+="${pkgs.btrfsProgs}/bin/btrfs device scan"
      '';
  };
}

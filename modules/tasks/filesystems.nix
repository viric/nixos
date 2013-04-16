{ config, pkgs, utils, ... }:

with pkgs.lib;
with utils;

let

  fileSystems = attrValues config.fileSystems;

  hasMultiDevices = fs: fs.devices != null;
  hasNotMultiDevices = fs: fs.devices == null;
  fileSystemsOneDevice = (filter hasNotMultiDevices fileSystems);
  fileSystemsMultiDevice = (filter hasMultiDevices fileSystems);

  fileSystemOpts = { name, ... }: {

    options = {

      mountPoint = mkOption {
        example = "/mnt/usb";
        type = types.uniq types.string;
        description = "Location of the mounted the file system.";
      };

      device = mkOption {
        default = null;
        example = "/dev/sda";
        type = types.uniq (types.nullOr types.string);
        description = "Location of the device.";
      };

      devices = mkOption {
        default = null;
        example = [ "/dev/sda" "/dev/sdb" ];
        type = types.uniq (types.nullOr (types.listOf types.string));
        description = "Location of the devices to depend on.";
      };

      label = mkOption {
        default = null;
        example = "root-partition";
        type = types.uniq (types.nullOr types.string);
        description = "Label of the device (if any).";
      };

      fsType = mkOption {
        default = "auto";
        example = "ext3";
        type = types.uniq types.string;
        description = "Type of the file system.";
      };

      options = mkOption {
        default = "defaults,relatime";
        example = "data=journal";
        type = types.string;
        merge = pkgs.lib.concatStringsSep ",";
        description = "Options used to mount the file system.";
      };

      autoFormat = mkOption {
        default = false;
        type = types.bool;
        description = ''
          If the device does not currently contain a filesystem (as
          determined by <command>blkid</command>, then automatically
          format it with the filesystem type specified in
          <option>fsType</option>.  Use with caution.
        '';
      };

      noCheck = mkOption {
        default = false;
        type = types.bool;
        description = "Disable running fsck on this filesystem.";
      };

    };

    config = {
      mountPoint = mkDefault name;
    };

  };

in

{

  ###### interface

  options = {

    fileSystems = mkOption {
      example = {
        "/".device = "/dev/hda1";
        "/data" = {
          device = "/dev/hda2";
          fsType = "ext3";
          options = "data=journal";
        };
        "/bigdisk".label = "bigdisk";
      };
      type = types.loaOf types.optionSet;
      options = [ fileSystemOpts ];
      description = ''
        The file systems to be mounted.  It must include an entry for
        the root directory (<literal>mountPoint = \"/\"</literal>).  Each
        entry in the list is an attribute set with the following fields:
        <literal>mountPoint</literal>, <literal>device</literal>,
        <literal>fsType</literal> (a file system type recognised by
        <command>mount</command>; defaults to
        <literal>\"auto\"</literal>), and <literal>options</literal>
        (the mount options passed to <command>mount</command> using the
        <option>-o</option> flag; defaults to <literal>\"defaults\"</literal>).

        Instead of specifying <literal>device</literal>, you can also
        specify a volume label (<literal>label</literal>) for file
        systems that support it, such as ext2/ext3 (see <command>mke2fs
        -L</command>).
      '';
    };

    system.fsPackages = mkOption {
      internal = true;
      default = [ ];
      description = "Packages supplying file system mounters and checkers.";
    };

    boot.supportedFilesystems = mkOption {
      default = [ ];
      example = [ "btrfs" ];
      type = types.listOf types.string;
      description = "Names of supported filesystem types.";
    };

    boot.initrd.supportedFilesystems = mkOption {
      default = [ ];
      example = [ "btrfs" ];
      type = types.listOf types.string;
      description = "Names of supported filesystem types in the initial ramdisk.";
    };

  };


  ###### implementation

  config = {

    boot.supportedFilesystems = map (fs: fs.fsType) fileSystems;

    boot.initrd.supportedFilesystems =
      map (fs: fs.fsType)
        (filter (fs: fs.mountPoint == "/" || fs.neededForBoot) fileSystems);

    # Add the mount helpers to the system path so that `mount' can find them.
    system.fsPackages = [ pkgs.dosfstools ];

    environment.systemPackages =
      [ pkgs.ntfs3g pkgs.cifs_utils ]
      ++ config.system.fsPackages;

    environment.etc.fstab.text =
      ''
        # This is a generated file.  Do not edit!

        # Filesystems.
        ${flip concatMapStrings fileSystemsOneDevice (fs:
            (if fs.device != null then fs.device else "/dev/disk/by-label/${fs.label}")
            + " " + fs.mountPoint
            + " " + fs.fsType
            + " " + fs.options
            + " 0"
            + " " + (if fs.fsType == "none" || fs.device == "none" || fs.fsType == "btrfs" || fs.fsType == "tmpfs" || fs.noCheck then "0" else
                     if fs.mountPoint == "/" then "1" else "2")
            + "\n"
        )}

        # Swap devices.
        ${flip concatMapStrings config.swapDevices (sw:
            "${sw.device} none swap\n"
        )}
      '';

    # Provide a target that pulls in all filesystems.
    systemd.targets.fs =
      { description = "All File Systems";
        wants = [ "local-fs.target" "remote-fs.target" ];
      };

    systemd.mounts =
      let
        mountUnit = fs:
          let
            mountPoint' = escapeSystemdPath fs.mountPoint;
            devicesString = concatStringsSep "," (map (p: escapeSystemdPath p) fs.devices);
          in
          { description = "Mount of ${devicesString}";
	    what = head fs.devices;
            after = [ "systemd-udev-settle.service" ];
            before = [ "local-fs.target" ];
            wantedBy = [ "local-fs.target" ];
            requires = map (p: (escapeSystemdPath p) + ".device") fs.devices;
            where = fs.mountPoint;
            type = fs.fsType;
            options = fs.options;
          };
      in map mountUnit fileSystemsMultiDevice;

    # Emit systemd services to format requested filesystems.
    systemd.services =
      let

        formatDevice = fs:
          let
            mountPoint' = escapeSystemdPath fs.mountPoint;
            device' = escapeSystemdPath fs.device;
          in nameValuePair "mkfs-${device'}"
          { description = "Initialisation of Filesystem ${fs.device}";
            wantedBy = [ "${mountPoint'}.mount" ];
            before = [ "${mountPoint'}.mount" "systemd-fsck@${device'}.service" ];
            require = [ "${device'}.device" ];
            after = [ "${device'}.device" ];
            path = [ pkgs.utillinux ] ++ config.system.fsPackages;
            script =
              ''
                if ! [ -e "${fs.device}" ]; then exit 1; fi
                # FIXME: this is scary.  The test could be more robust.
                type=$(blkid -p -s TYPE -o value "${fs.device}" || true)
                if [ -z "$type" ]; then
                  echo "creating ${fs.fsType} filesystem on ${fs.device}..."
                  mkfs.${fs.fsType} "${fs.device}"
                fi
              '';
            unitConfig.RequiresMountsFor = [ "${dirOf fs.device}" ];
            unitConfig.DefaultDependencies = false; # needed to prevent a cycle
            serviceConfig.Type = "oneshot";
          };

      in listToAttrs (map formatDevice (filter (fs: fs.autoFormat) fileSystems));

  };

}

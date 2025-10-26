{
  armbian-kernel,
  config,
  lib,
  pkgs,
}:

pkgs.replaceVarsWith {
  src = ./extlinux-conf-builder.sh;
  isExecutable = true;
  replacements = {
    path = lib.makeBinPath [
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
    ];
    rootDevice = config.fileSystems."/".device or "";
    kernelPath = armbian-kernel.packages.aarch64-linux.kernel;
    inherit (pkgs) bash;
  };
}

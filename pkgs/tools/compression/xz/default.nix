{ lib, stdenv, fetchurl
, enableStatic ? stdenv.hostPlatform.isStatic
, writeScript
}:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

stdenv.mkDerivation rec {
  pname = "xz";
  version = "5.4.6";

  src = fetchurl {
    url = "https://github.com/tukaani-project/xz/releases/download/v${version}/xz-${version}.tar.bz2";
    sha256 = "sha256-kThRsnTo4dMXgeyUnxwj6NvPDs9uc6JDbcIXad0+b0k=";
  };

  strictDeps = true;
  outputs = [ "bin" "dev" "out" "man" "doc" ];

  configureFlags = lib.optional enableStatic "--disable-shared";

  enableParallelBuilding = true;
  doCheck = true;

  preCheck = ''
    # Tests have a /bin/sh dependency...
    patchShebangs tests
  '';

  # In stdenv-linux, prevent a dependency on bootstrap-tools.
  preConfigure = "CONFIG_SHELL=/bin/sh";

  postInstall = "rm -rf $out/share/doc";

  passthru = {
    updateScript = writeScript "update-xz" ''
      #!/usr/bin/env nix-shell
      #!nix-shell -i bash -p curl pcre common-updater-scripts

      set -eu -o pipefail

      # Expect the text in format of '>xz-5.2.6.tar.bz2</a>'
      # We pick first match where a stable release goes first.
      new_version="$(curl -s https://tukaani.org/xz/ |
          pcregrep -o1 '>xz-([0-9.]+)[.]tar[.]bz2</a>' |
          head -n1)"
      update-source-version ${pname} "$new_version"
    '';
  };

  meta = with lib; {
    homepage = "https://tukaani.org/xz/";
    description = "A general-purpose data compression software, successor of LZMA";

    longDescription =
      '' XZ Utils is free general-purpose data compression software with high
         compression ratio.  XZ Utils were written for POSIX-like systems,
         but also work on some not-so-POSIX systems.  XZ Utils are the
         successor to LZMA Utils.

         The core of the XZ Utils compression code is based on LZMA SDK, but
         it has been modified quite a lot to be suitable for XZ Utils.  The
         primary compression algorithm is currently LZMA2, which is used
         inside the .xz container format.  With typical files, XZ Utils
         create 30 % smaller output than gzip and 15 % smaller output than
         bzip2.
      '';

    license = with licenses; [ gpl2Plus lgpl21Plus ];
    maintainers = with maintainers; [ sander ];
    platforms = platforms.all;
  };
}

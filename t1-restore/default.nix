# =============================================================================
#  T1 EmbeddedOS restore toolchain (Route 2 — no macOS required)
# -----------------------------------------------------------------------------
#  Builds the exact pinned libimobiledevice stack the T1 activation was verified
#  against, plus two patches we can specify precisely:
#    * libirecovery: add the Apple T1 iBridge (x619ap, CPID 0x8002, BDID 0x12)
#      to the device table, so it is recognised in recovery.
#    * usbmuxd: widen the libusb hotplug device-class filter to MATCH_ANY so it
#      can see the T1's restored interface.
#
#  STATUS: the toolchain builds and runs. The remaining piece is the
#  idevicerestore "EmbeddedOS activation" logic (FDR memory store, preflight
#  capture, phase 14 blind memboot) — see README.md.
#
#  Usage:
#    nix-build /etc/nixos/t1-restore            # builds the tools
#    nix-shell /etc/nixos/t1-restore -A t1-restore
# =============================================================================
{ pkgs ? import <nixpkgs> { } }:

let
  inherit (pkgs) lib;

  pin = { owner, repo, rev, hash }: pkgs.fetchFromGitHub { inherit owner repo rev hash; };

  sources = {
    libplist = pin { owner = "libimobiledevice"; repo = "libplist"; rev = "32428ab"; hash = "sha256-MrHeoDWcbflGDjZ8f4pOM7e8d9BeS5JH/Oo/8j9nQ7U="; };
    glue = pin { owner = "libimobiledevice"; repo = "libimobiledevice-glue"; rev = "da770a7"; hash = "sha256-xIeDMn9N7GohiPoi6yZ8B5xoGWu5MkScRaNb4A8IkMY="; };
    libtatsu = pin { owner = "libimobiledevice"; repo = "libtatsu"; rev = "60a39f3"; hash = "sha256-beBNyuGizQKB9OYsPZh5wffH+8ben40x/lSQ9U2w8GA="; };
    libirecovery = pin { owner = "libimobiledevice"; repo = "libirecovery"; rev = "95dec3a"; hash = "sha256-k8aHdfqqMBDOnzyp+4SBTIbXiro2DhDywFAu4o6VhaY="; };
    libusbmuxd = pin { owner = "libimobiledevice"; repo = "libusbmuxd"; rev = "93eb168"; hash = "sha256-yQBKUrkG3WAxhmniXyJ0qnRyETwW7VkVNL2omiLXUHs="; };
    libimobiledevice = pin { owner = "libimobiledevice"; repo = "libimobiledevice"; rev = "fa0f791"; hash = "sha256-YDZl5pSlPoqtSJmvoVApx5Y23wurMH8k4dPlLDesLPM="; };
    usbmuxd = pin { owner = "libimobiledevice"; repo = "usbmuxd"; rev = "3ded00c"; hash = "sha256-0ZxEdU6LAUT0XfRk/PnRGl+r2ofttpffI8MiQljukVA="; };
    idevicerestore = pin { owner = "libimobiledevice"; repo = "idevicerestore"; rev = "540c352"; hash = "sha256-VkTlMM94LaE68bnZI7I/dKShGHzbMFOAGeqP73RZRko="; };
  };

  mkLib = { pname, version, src, buildInputs ? [ ], configureFlags ? [ ], postPatch ? "", ... }@args:
    pkgs.stdenv.mkDerivation (lib.recursiveUpdate {
      inherit pname version src;
      nativeBuildInputs = [
        pkgs.autoconf pkgs.automake pkgs.libtool pkgs.pkg-config
        pkgs.autoconf-archive pkgs.gettext pkgs.which pkgs.git
      ];
      inherit buildInputs configureFlags postPatch;
      preConfigure = ''
        echo "${version}" > .tarball-version
        NOCONFIGURE=1 ./autogen.sh
      '';
      hardeningDisable = [ "format" ];
      enableParallelBuilding = true;
    } (removeAttrs args [ "pname" "version" "src" "buildInputs" "configureFlags" "postPatch" ]));

  libplist = mkLib {
    pname = "libplist";
    version = "2.7.0";
    src = sources.libplist;
    buildInputs = [ pkgs.libxml2 ];
    configureFlags = [ "--without-cython" ];
  };

  glue = mkLib {
    pname = "libimobiledevice-glue";
    version = "1.3.2";
    src = sources.glue;
    buildInputs = [ libplist ];
  };

  libtatsu = mkLib {
    pname = "libtatsu";
    version = "1.0.5";
    src = sources.libtatsu;
    buildInputs = [ libplist pkgs.curl pkgs.openssl ];
  };

  # PATCH: recognise the T1 iBridge in recovery mode.
  libirecovery = mkLib {
    pname = "libirecovery";
    version = "1.3.1";
    src = sources.libirecovery;
    buildInputs = [ libplist glue pkgs.libusb1 pkgs.readline ];
    configureFlags = [
      "--with-udevrule=OWNER=\"root\", GROUP=\"root\", MODE=\"0660\""
      "--with-udevrulesdir=${placeholder "out"}/lib/udev/rules.d"
    ];
    postPatch = ''
      sed -i '/"Watch2,4".*Apple Watch Series 2 (42mm)/a\
	{ "Watch2,5",    "x619ap",  0x12, 0x8002, "Apple T1 iBridge (MacBookPro13,2/13,3)" },\
	{ "Watch2,5",    "x619dev", 0x13, 0x8002, "Apple T1 iBridge dev (MacBookPro13,2/13,3)" },' \
        src/libirecovery.c
      grep -n "Apple T1 iBridge" src/libirecovery.c
    '';
  };

  libusbmuxd = mkLib {
    pname = "libusbmuxd";
    version = "2.1.1";
    src = sources.libusbmuxd;
    buildInputs = [ libplist glue ];
  };

  libimobiledevice = mkLib {
    pname = "libimobiledevice";
    version = "1.4.0";
    src = sources.libimobiledevice;
    buildInputs = [ libplist glue libusbmuxd libtatsu pkgs.openssl pkgs.libusb1 pkgs.readline ];
    configureFlags = [ "--without-cython" ];
  };

  # PATCH: widen the hotplug device-class filter so the T1 restored interface is seen.
  usbmuxd = mkLib {
    pname = "usbmuxd";
    version = "1.1.1";
    src = sources.usbmuxd;
    buildInputs = [ libplist glue libimobiledevice pkgs.libusb1 ];
    configureFlags = [
      "--without-systemd"
      "--with-udevrulesdir=${placeholder "out"}/lib/udev/rules.d"
    ];
    postPatch = ''
      substituteInPlace src/usb.c \
        --replace-fail "VID_APPLE, LIBUSB_HOTPLUG_MATCH_ANY, 0," \
                       "VID_APPLE, LIBUSB_HOTPLUG_MATCH_ANY, LIBUSB_HOTPLUG_MATCH_ANY,"
      grep -n "libusb_hotplug_register_callback" src/usb.c
    '';
  };

  # idevicerestore — T1 EmbeddedOS activation patches (see patches/).
  idevicerestore = mkLib {
    pname = "idevicerestore";
    version = "1.0.0";
    src = sources.idevicerestore;
    patches = [ ./patches/0001-t1-embeddedos.patch ];
    buildInputs = [
      libplist glue libtatsu libirecovery libusbmuxd libimobiledevice
      pkgs.libzip pkgs.curl pkgs.openssl pkgs.zlib
    ];
  };

  t1-restore = pkgs.buildEnv {
    name = "t1-restore";
    paths = [ idevicerestore usbmuxd libirecovery libimobiledevice libplist pkgs.usbutils pkgs.zstd ];
  };
in
{
  inherit libplist glue libtatsu libirecovery libusbmuxd libimobiledevice usbmuxd idevicerestore t1-restore;
}

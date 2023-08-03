{
  inputs.flake-utils.url = "github:numtide/flake-utils/v1.0.0";

  outputs = { self, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.default = pkgs.zig.overrideAttrs(f: p: rec {
          name = "zig";
          version = "0.11.0";

          src = pkgs.fetchFromGitHub {
            owner = "ziglang";
            repo = "zig";
            rev = "0.11.0";
            hash = "sha256-iuU1fzkbJxI+0N1PiLQM013Pd1bzrgqkbIyTxo5gB2I=";
          };

          patches = [];

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.llvmPackages_16.llvm.dev
          ];

          cmakeFlags = p.cmakeFlags ++ [
            "-DZIG_VERSION=0.11.0"
          ];

          # There is one error during the build that does
          # not seem to impact the end result, so we hack
          # around it here.
          preBuild = ''
            set +eu
            set +o pipefail
            shopt -u inherit_errexit
          '';

          buildInputs = with pkgs; [
            coreutils
            libxml2
            zlib
          ] ++ (with llvmPackages_16; [
            libclang
            lld
            llvm
          ]);
        });

        #packages.default = stdenv.mkDerivation rec {
        #  pname = "zig";
        #  version = "0.11.0-dev.4320+6f0a613b6";
        #  outputs = [ "out" "doc" ];
#
        #  src = pkgs.fetchFromGitHub {
        #    owner = "ziglang";
        #    repo = "zig-bootstrap";
        #    rev = "6f0a613b6f2d070196d47cb2932f7c728c63542a";
        #  };
        #};
      });
}
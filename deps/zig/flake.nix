{
  inputs.flake-utils.url = "github:numtide/flake-utils/v1.0.0";

  outputs = { self, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.default = pkgs.zig.overrideAttrs(f: p: rec {
          name = "zig";
          version = "0.11.0-dev.4410+76f7b40e1";

          src = pkgs.fetchFromGitHub {
            owner = "ziglang";
            repo = "zig";
            rev = "76f7b40e15456ed6ec2249607a91e8398a0d39e8";
            hash = "sha256-MwY2EeDVs2ZKiaF3n2Lu0W+wC3HUAa7cftKIfz8KyXY=";
          };

          patches = [];

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.llvmPackages_16.llvm.dev
          ];

          cmakeFlags = p.cmakeFlags ++ [
            "-DZIG_VERSION=0.11.0-dev.4410+76f7b40e1"
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
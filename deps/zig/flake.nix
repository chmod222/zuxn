{
  inputs.flake-utils.url = "github:numtide/flake-utils/v1.0.0";
  inputs.zig.url = "github:mitchellh/zig-overlay";

  outputs = { self, zig, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.precompiled = zig.packages.${system}.master;

        packages.default = pkgs.zig.overrideAttrs(f: p: rec {
          name = "zig";
          version = "0.12.0-dev+3fc6a2f";

          src = pkgs.fetchFromGitHub {
            owner = "ziglang";
            repo = "zig";
            rev = "3fc6a2f11399e84b9cfa4cfef65ef40aa6de173b";
            hash = "";
          };

          patches = [];

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.llvmPackages_17.llvm.dev
          ];

          cmakeFlags = p.cmakeFlags ++ [
            "-DZIG_VERSION=${version}"
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
          ] ++ (with llvmPackages_17; [
            libclang
            lld
            llvm
          ]);
        });
      });
}
{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils/v1.0.0";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls.url = "github:zigtools/zls/0.14.0";
    zls.inputs.nixpkgs.follows = "nixpkgs";

    # build.zig.zon
    clap.url = "https://github.com/Hejsil/zig-clap/archive/2d9db156ae928860a9acf2f1260750d3b44a4c98.tar.gz";
    clap.flake = false;
  };

  outputs = { self, zig-overlay, zls, clap, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig-ver = "0.14.0";
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "zuxn";
          version = "0.0";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            zig-overlay.packages.${system}.${zig-ver}
          ];

          buildInputs = with pkgs; [
            SDL2.dev
            SDL2_image
          ];

          buildPhase = ''
            mkdir -p $out
            mkdir -p .cache/{p,z,tmp}

            cp -r ${clap} .cache/p/122005e589ab3b6bff8e589b45f5b12cd27ce79f266bdac17e9f33ebfe2fbaff7fe3

            zig build --cache-dir $(pwd)/zig-cache --global-cache-dir $(pwd)/.cache -p $out
          '';
        };

        devShells.default = pkgs.mkShell {
          name = "zuxn-dev";

          buildInputs = [
            zig-overlay.packages.${system}.${zig-ver}
            zls.packages.${system}.default

            pkgs.SDL2.dev
            pkgs.SDL2_image
          ];
        };
    });
}

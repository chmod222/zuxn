{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils/v1.0.0";

    zig = {
      url = "path:deps/zig";

      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    # build.zig.zon
    clap.url = "https://github.com/Hejsil/zig-clap/archive/f49b94700e0761b7514abdca0e4f0e7f3f938a93.tar.gz";
    clap.flake = false;
  };

  outputs = { self, zig, clap, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "zuxn";
          version = "0.0";

          src = ./.;

          nativeBuildInputs = with pkgs; [
            zig.packages.${system}.precompiled
          ];

          buildInputs = with pkgs; [
            SDL2.dev
            SDL2_image
          ];

          buildPhase = ''
            mkdir -p $out
            mkdir -p .cache/{p,z,tmp}

            cp -r ${clap} .cache/p/12204b2fb733b2de9184d1907032709e79c2595b4adc9bed12a8383b114d4c0da932

            zig build --cache-dir $(pwd)/zig-cache --global-cache-dir $(pwd)/.cache -p $out
          '';
        };

        devShells.default = pkgs.mkShell {
          name = "zuxn-dev";

          buildInputs = [
            zig.packages.${system}.precompiled

            pkgs.zls

            pkgs.SDL2.dev
            pkgs.SDL2_image
          ];
        };
    });
}

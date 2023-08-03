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
    clap.url = "https://github.com/Hejsil/zig-clap/archive/bdb5853b678d68f342ec65b04a6785af522ca6c9.tar.gz";
    clap.flake = false;
  };

  outputs = { self, zig, clap, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigc = zig.packages.${system}.default;
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "zuxn";
          version = "0.0";

          src = ./.;

          nativeBuildInputs = [
            zigc
          ];

          buildInputs = with pkgs; [
            SDL2.dev
            SDL2_image
          ];

          buildPhase = ''
            mkdir -p $out
            mkdir -p .cache/{p,z,tmp}

            cp -r ${clap} .cache/p/12202af04ec78191f2018458a7be29f54e0d9118f7688e7a226857acf754d68b8473

            zig build --cache-dir $(pwd)/zig-cache --global-cache-dir $(pwd)/.cache -p $out
          '';
        };

        devShells.default = pkgs.mkShell {
          name = "zuxn-dev";

          buildInputs = [
            zigc

            pkgs.SDL2.dev
            pkgs.SDL2_image
          ];
        };
    });
}

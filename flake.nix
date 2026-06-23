{
  description = "Headless BitTorrent client daemon and CLI written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = pkgs.zig_0_16;
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "nix-torrent";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              zig build -Doptimize=ReleaseSafe --cache-dir .zig-cache --global-cache-dir .zig-global-cache
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r zig-out/* $out/
              runHook postInstall
            '';
          };
        });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = pkgs.zig_0_16;
        in {
          default = pkgs.mkShell {
            packages = [ zig ];
          };
        });
    };
}

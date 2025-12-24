{
  description = "A Matrix homeserver, powered by the BEAM";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    # from https://github.com/the-nix-way/dev-templates/blob/main/elixir/flake.nix#L10
    let
      supportedSystems = [
        {
          system = "x86_64-linux";
          target = "linux-x64";
        }
        {
          system = "aarch64-linux";
          target = "linux-arm64";
        }
      ];
      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs (map ({ system, ... }: system) supportedSystems) (
          system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              # overlays = [ inputs.self.overlays.default ];
            };
          }
        );
    in
    {
      # packages.x86_64-linux.hello = nixpkgs.legacyPackages.x86_64-linux.hello;
      #
      # packages.x86_64-linux.default = self.packages.x86_64-linux.hello;

      devShells = forEachSupportedSystem (
        { pkgs }:
        let
          supportedSystem = nixpkgs.lib.findFirst (
            { system, ... }: system == pkgs.system
          ) "linux-x64" supportedSystems;
        in
        {
          default = import ./shell.nix {
            inherit pkgs;
            target = supportedSystem.target;
          };
        }
      );
    };
}

{
  description = "hugo blog";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      poetry2nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      with pkgs;
      rec {
        # Development environment
        devShell = mkShell {
          name = "hugo-blog";
          nativeBuildInputs = [
            bash
            entr
            hugo
          ];
        };
      }
    );
}

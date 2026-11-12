{
  description = "Lean 4 major mode built on built-in facilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    keg.url = "github:conao3/keg.el";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        { pkgs, system, ... }:
        let
          emacs = pkgs.emacs31;
          pkg = emacs.pkgs.trivialBuild {
            pname = "leaner-ts-mode";
            version = "0.0.1";
            src = pkgs.lib.cleanSourceWith {
              src = ./.;
              filter = path: _: !(pkgs.lib.hasSuffix "-tests.el" path);
            };
          };
          emacsWithPackage = emacs.pkgs.withPackages (_: [ pkg ]);
        in
        {
          packages.default = pkgs.writeShellApplication {
            name = "leaner-ts-mode";
            text = ''exec ${emacsWithPackage}/bin/emacs -Q --eval "(require 'leaner-ts-mode)" "$@"'';
          };

          devShells.default = pkgs.mkShell {
            packages = [
              emacs
              pkgs.gnumake
              inputs.keg.packages.${system}.default
            ];
          };

          treefmt.programs.nixfmt.enable = true;
        };
    };
}

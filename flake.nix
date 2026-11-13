{
  description = "Lean 4 major mode using tree-sitter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    keg.url = "github:conao3/keg.el";
    lean-grammar = {
      url = "github:lua-vr/tree-sitter-lean-flat/d3c99bdcfad217d289bc513c51e6f825fcf9484f";
      flake = false;
    };
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
          grammar = pkgs.stdenv.mkDerivation {
            pname = "tree-sitter-lean-flat";
            version = "d3c99bd";
            src = inputs.lean-grammar;
            buildPhase = ''
              runHook preBuild
              $CC ${
                if pkgs.stdenv.hostPlatform.isDarwin then "-dynamiclib" else "-shared"
              } -fPIC -O2 -I src src/parser.c -o libtree-sitter-leanflat${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 libtree-sitter-leanflat${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/libtree-sitter-leanflat${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
              runHook postInstall
            '';
          };
          pkg = emacs.pkgs.trivialBuild {
            pname = "leaner-ts-mode";
            version = "0.2.0";
            src = pkgs.lib.cleanSourceWith {
              src = ./.;
              filter = path: _: baseNameOf path != "test";
            };
          };
          emacsWithPackage = emacs.pkgs.withPackages (_: [ pkg ]);
        in
        {
          packages.default = pkgs.writeShellApplication {
            name = "leaner-ts-mode";
            runtimeInputs = [
              pkgs.lean4
              pkgs.stdenv.cc
              pkgs.gnumake
            ];
            text = ''exec ${emacsWithPackage}/bin/emacs -Q --eval "(add-to-list 'treesit-extra-load-path \"${grammar}/lib\")" --eval "(require 'leaner-ts-mode)" "$@"'';
          };

          packages.grammar = grammar;

          devShells.default = pkgs.mkShell {
            packages = [
              emacs
              pkgs.gnumake
              pkgs.lean4
              inputs.keg.packages.${system}.default
            ];
            shellHook = ''
              export LEANER_TS_GRAMMAR_DIR="${grammar}/lib"
            '';
          };

          treefmt.programs.nixfmt.enable = true;
        };
    };
}

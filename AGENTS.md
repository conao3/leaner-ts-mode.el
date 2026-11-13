# AGENTS.md

`leaner-ts-mode.el` is an Emacs Lisp package: Lean 4 major mode using tree-sitter.

## Layout

- `leaner-ts-mode.el`: the package.
- `test/leaner-ts-mode-tests.el`: tests written with cort. The test file does not provide a feature, as MELPA requires.
- `Keg`: package recipe and development dependencies for keg.
- `Makefile`: the build, lint, test, and check targets.
- `flake.nix`: the development shell (Emacs, GNU Make, keg), `nix run` (Emacs with the package loaded), and `nix fmt`.
- `.github/workflows/ci.yml`: runs `make check` on every Emacs version in the matrix.

## Verification

Run the checks inside the development shell:

```sh
nix develop --command make check
```

`make check` runs `keg lint` and the cort tests. CI runs the same target.

The tests use a real tree-sitter-lean-flat grammar. The development shell
builds it and exports `LEANER_TS_GRAMMAR_DIR`; CI installs it with
`leaner-ts-install-grammar`. Test mode activation and editing behavior with
the parser enabled. The grammar is loaded as `leanflat`, with the library
name `libtree-sitter-leanflat` and the C entry point `tree_sitter_lean`.

## Conventions

- Prefix every symbol with `leaner-ts-` (the package name without `-mode`, as in `clojure-ts-mode`). Name each additional file `leaner-ts-<part>.el`.
- Keep the lower bound of `Package-Requires` in the CI matrix.
- When a workflow or a `uses:` line changes, run `gh actions-lock` and commit `.github/workflows/actions.lock` together with the workflow.

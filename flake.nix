{
  description = "Latent Shell: Python hosts, Mojo computes, Nix builds";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2c423e03bbafcff28bfadc6781a4a8257f205cb5";
  inputs.mojo-json = {
    url = "github:ehsanmok/json/bc2c0e8378aa5eb8c61f40dd16b4f3b1473cfd34";
    flake = false;
  };
  inputs.ts-to-python = {
    url = "github:pyodide/ts-to-python/aa02341e78e8c2facf53a7d8a3ce98da2aa84ff5";
    flake = false;
  };
  inputs.toybox = {
    url = "github:landley/toybox/0.8.13";
    flake = false;
  };
  inputs.git-hooks = {
    url = "github:cachix/git-hooks.nix/27555e2624241fb116b49095df4caaee85a25691";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      mojo-json,
      git-hooks,
      ts-to-python,
      toybox,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      context =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "mojo";
          };
          mojo = pkgs.callPackage ./nix/mojo.nix { };
          toyboxUserspace = pkgs.callPackage ./nix/toybox.nix {
            toyboxSource = toybox;
            muslSource = pkgs.musl.src;
          };
          wasm = pkgs.callPackage ./nix/wasm.nix {
            inherit mojo;
            userspace = toyboxUserspace;
            mojoJson = mojo-json;
            wasiLibcSource = pkgs.wasilibc.src;
            compilerRtSource = pkgs.llvmPackages.compiler-rt.src;
            wasmTools = pkgs.wasm-tools;
          };
          xterm = pkgs.callPackage ./nix/xterm.nix { };
          browserHost = import ./nix/browser.nix {
            inherit pkgs xterm;
            lib = pkgs.lib;
            tsSource = ts-to-python;
          };
          codexCatalog = pkgs.callPackage ./nix/codex.nix { };
          static = pkgs.runCommand "latent-shell-static" { } ''
            mkdir -p "$out"
            cp ${xterm}/xterm.js ${xterm}/xterm.css ${xterm}/xterm-fit.js "$out/"
            cp -R ${xterm}/licenses "$out/"
            cp ${wasm}/shell.wasm "$out/shell.wasm"
            cp ${browserHost}/host.js "$out/host.js"
          '';
          hooks = git-hooks.lib.${system}.run {
            src = self;
            hooks = {
              source-surface = {
                enable = true;
                name = "source-surface";
                entry = "${pkgs.python313}/bin/python ${./tools/check_source_surface.py}";
                pass_filenames = false;
                always_run = true;
              };
              nixfmt.enable = true;
              ruff.enable = true;
              ruff-format.enable = true;
              trim-trailing-whitespace.enable = true;
              end-of-file-fixer.enable = true;
            };
          };
          sourceSurface =
            pkgs.runCommand "source-surface"
              {
                src = self;
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.python313
                ];
              }
              ''
                export HOME="$TMPDIR"
                cp -R "$src" repository
                chmod -R u+w repository
                cd repository
                git init -q
                # The flake snapshot is already the tracked source. Preserve even
                # force-tracked ignored paths when constructing its check index.
                git add --force -- .
                python tools/check_source_surface.py
                python -m unittest tests.test_source_surface
                touch "$out"
              '';
        in
        {
          inherit
            pkgs
            mojo
            wasm
            xterm
            static
            hooks
            sourceSurface
            browserHost
            codexCatalog
            toyboxUserspace
            ;
        };
    in
    {
      packages = eachSystem (
        system:
        let
          ctx = context system;
        in
        {
          default = ctx.static;
          wasm = ctx.wasm;
          browser-host = ctx.browserHost;
        }
      );
      checks = eachSystem (
        system:
        let
          ctx = context system;
        in
        {
          source-surface = ctx.sourceSurface;
          pre-commit = ctx.hooks;
          wasm = ctx.wasm;
          browser-host = ctx.browserHost;
        }
      );
      formatter = eachSystem (system: (context system).pkgs.nixfmt);
      devShells = eachSystem (
        system:
        let
          ctx = context system;
        in
        {
          default = ctx.pkgs.mkShell {
            packages = [
              ctx.mojo
              ctx.browserHost.compiler
              ctx.pkgs.uv
              ctx.pkgs.git
              ctx.pkgs.llvmPackages.lld
              ctx.pkgs.llvmPackages.llvm
              ctx.pkgs.wasm-tools
            ]
            ++ ctx.hooks.enabledPackages;
            MOJO_JSON_PATH = "${mojo-json}";
            LATENT_STATIC_DIR = "${ctx.static}";
            LATENT_CODEX_CATALOG = "${ctx.codexCatalog}/models.json";
            LATENT_USERSPACE_LIB = "${ctx.toyboxUserspace}/lib/liblatent-userspace-native.a";
            # Mojo's native test executables need the pinned C++ runtime.
            LD_LIBRARY_PATH = ctx.pkgs.lib.makeLibraryPath [ ctx.pkgs.stdenv.cc.cc.lib ];
            MYPYPATH = "${ctx.browserHost.types}";
            UV_PYTHON = "${ctx.pkgs.python313}/bin/python3";
            UV_PYTHON_DOWNLOADS = "never";
            shellHook = ctx.hooks.shellHook + ''
              export MODULAR_CACHE_DIR="''${TMPDIR:-/tmp}"
            '';
          };
        }
      );
    };
}

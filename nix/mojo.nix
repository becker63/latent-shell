{
  lib,
  fetchurl,
  unzip,
  stdenv,
  makeWrapper,
  binutils,
  patchelf,
}:

# Mojo 1.0.0 hermetic toolchain for Latent Shell.
#
# The official Mojo distribution ships as five PyPI wheels.  Only their native
# payloads are used here (`modular/bin`, `modular/lib`).  We do not install a
# Python package, do not use Pixi/Conda, and do not introduce a second
# environment authority: Nix remains the toolchain authority; this derivation
# merges the pinned wheels into one immutable tree, and wrappers expose the
# compiler and language server with the same self-contained environment. Project
# builds never depend on ambient PATH Mojo.

let
  # Architecture-specific wheels are independent PyPI artifacts, not renamed
  # ARM payloads. The original ARM URLs/hashes remain unchanged.
  wheelSpecs =
    (
      if stdenv.hostPlatform.system == "x86_64-linux" then
        [
          {
            name = "mojo_compiler-1.0.0-py3-none-manylinux_2_34_x86_64.whl";
            url = "https://files.pythonhosted.org/packages/f0/5f/f38fefe327d1c81e28def69c4a52ae4f75e389cb6e613a2c04ca8d68d582/mojo_compiler-1.0.0-py3-none-manylinux_2_34_x86_64.whl";
            sha256 = "e9e60f9638e69ca0f4be7292468523fc98a143f58dbf9024f60ed68b874a867e";
          }
          {
            name = "mojo-1.0.0-py3-none-manylinux_2_34_x86_64.whl";
            url = "https://files.pythonhosted.org/packages/c4/89/326637e71282288e7d3a8ef2990dbf9fbfb07c1b3d21b836ffe2ee3111a9/mojo-1.0.0-py3-none-manylinux_2_34_x86_64.whl";
            sha256 = "725d6b7f29a5a3334e3c225f35f2b709fd46151a0a31a2c22738b1937dfc83d9";
          }
          {
            name = "mojo_lldb_libs-1.0.0-py3-none-manylinux_2_34_x86_64.whl";
            url = "https://files.pythonhosted.org/packages/12/a0/8280a1869d017102d50e0dcf1962e0bc59834f8fe07b435e1a575bb5c923/mojo_lldb_libs-1.0.0-py3-none-manylinux_2_34_x86_64.whl";
            sha256 = "de151c87f3fb4d184a85e735eae05bf43f9a9deb4cb8f2b07cf6b59cb769d93f";
          }
        ]
      else if stdenv.hostPlatform.system == "aarch64-linux" then
        [
          {
            # Compiler driver: MODULAR_MOJO_MAX_DRIVER_PATH -> bin/mojo
            name = "mojo_compiler-1.0.0-py3-none-manylinux_2_34_aarch64.whl";
            url = "https://files.pythonhosted.org/packages/34/8c/3ae3eb0c58a8956f542e324f736866df0ae2f9f875e8a279cbeea961ec4e9ee8/mojo_compiler-1.0.0-py3-none-manylinux_2_34_aarch64.whl";
            sha256 = "3ae3eb0c58a8956f542e324f736866df0ae2f9f875e8a279cbeea961ec4e9ee8";
          }
          {
            # Developer CLI wrappers (lldb*, lsp, gpu-query) + mblack entrypoints
            name = "mojo-1.0.0-py3-none-manylinux_2_34_aarch64.whl";
            url = "https://files.pythonhosted.org/packages/31/e3/d429fb53aa018e592dc378def8a92c67d0978078c8c30d089019195a285f/mojo-1.0.0-py3-none-manylinux_2_34_aarch64.whl";
            sha256 = "a6db18b2846ec4877c5cd43a2dce1556400520dc0d4450dc8b4703dab569e9a2";
          }
          {
            # lldb runtime libraries
            name = "mojo_lldb_libs-1.0.0-py3-none-manylinux_2_34_aarch64.whl";
            url = "https://files.pythonhosted.org/packages/38/e1/a7c6c73c875f5692587beda9ca68773bae069d60b1c79d9fffd8a2840f4d/mojo_lldb_libs-1.0.0-py3-none-manylinux_2_34_aarch64.whl";
            sha256 = "7eb1f204829f031fda8cc9ee4e7f461f1ca3ddf1c8fb509abf2eb6f02c9de4f5";
          }
        ]
      else
        throw "Mojo 1.0 is pinned here for Linux ARM64 and x86-64 only"
    )
    ++ [
      {
        # precompiled std (modular/lib/mojo/std.mojoc), architecture-independent
        name = "mojo_compiler_mojo_libs-1.0.0-py3-none-any.whl";
        url = "https://files.pythonhosted.org/packages/e8/e5/20a92e37ecbd19e2dbb1a525612a8de4c9f266f5536def55c5e2b0786320e8b3/mojo_compiler_mojo_libs-1.0.0-py3-none-any.whl";
        sha256 = "20a92e37ecbd19e2dbb1a525612a8de4c9f266f5536def55c5e2b0786320e8b3";
      }
      {
        # mblack formatter dependency (data only; keeps the wheel closure hermetic)
        name = "mblack-26.5.0-py3-none-any.whl";
        url = "https://files.pythonhosted.org/packages/f0/36/8147d0627cde9043557f7906eabe64ff6295ec910dade5251e5703f0f6d9/mblack-26.5.0-py3-none-any.whl";
        sha256 = "072b304646c277979e6a1d19b086ef226bb7381810902e975cf1c3886d1d7883";
      }
    ];

  wheels = map (
    spec:
    fetchurl {
      url = spec.url;
      sha256 = spec.sha256;
      name = spec.name;
    }
  ) wheelSpecs;
in
stdenv.mkDerivation {
  pname = "mojo";
  version = "1.0.0";

  src = null;
  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [
    unzip
    makeWrapper
  ];

  buildPhase = ''
    merge() {
      mkdir -p "$out/merged"
      for w in ${lib.concatStringsSep " " (map toString wheels)}; do
        # wheels include dist-info and .data/platlib; merge native payloads only
        unzip -q "$w" -d "$out/raw"
      done
      for item in "$out/raw"/*; do
        base=$(basename "$item")
        if [[ "$base" == *.data ]]; then
          cp -a "$item/platlib/." "$out/merged/"
        elif [[ "$base" == *.dist-info ]]; then
          : # metadata is not needed at runtime
        else
          cp -a "$item" "$out/merged/"
        fi
      done
    }
    merge
  '';

  installPhase = ''
        tree="$out/merged/modular"
        mkdir -p "$out/bin"

        # Keep the compiler, language server, linker, standard library, and runtime.
        # The extraction tree duplicates the merged payload; LLDB/Jupyter binaries
        # remain unrelated to compilation or editor analysis.
        rm -rf "$out/raw"
        rm -f \
          "$tree/bin/gpu-query" \
          "$tree/bin/lldb-argdumper" \
          "$tree/bin/lldb-dap" \
          "$tree/bin/lldb-server" \
          "$tree/bin/mojo-lldb" \
          "$tree/lib/libMojoJupyter.so" \
          "$tree/lib/libMojoLLDB.so" \
          "$tree/lib/liblldb24.0.0git.so" \
          "$tree/lib/mojo-repl-entry-point"

        # The official manylinux wheels name the FHS loader directly.  Rewrite
        # every shipped executable to the Nix glibc loader so Mojo is usable as a
        # native build tool inside another pure derivation, not only through the
        # host's nix-ld compatibility path.
        while IFS= read -r -d ''' executable; do
          if ${patchelf}/bin/patchelf --print-interpreter "$executable" >/dev/null 2>&1; then
            ${patchelf}/bin/patchelf \
              --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
              "$executable"
          fi
        done < <(find "$tree/bin" -type f -print0)

        # Self-contained cc/linker path so `mojo build` can link hermetically.
        mkdir -p "$out/toolchain-bin"
        for t in cc gcc c++ g++ ld as ar ranlib objcopy strip nm; do
          for src in ${stdenv.cc}/bin/$t ${binutils}/bin/$t; do
            if [ -e "$src" ] && [ ! -e "$out/toolchain-bin/$t" ]; then
              ln -s "$src" "$out/toolchain-bin/$t"
            fi
          done
        done

        makeWrapper "$tree/bin/mojo" "$out/bin/mojo" \
          --set MODULAR_MAX_PACKAGE_ROOT "$tree" \
          --set MODULAR_MOJO_MAX_PACKAGE_ROOT "$tree" \
          --set MODULAR_MOJO_MAX_DRIVER_PATH "$tree/bin/mojo" \
          --set MODULAR_MOJO_MAX_IMPORT_PATH "$tree/lib/mojo" \
          --set MODULAR_MOJO_MAX_CRASHPAD_HANDLER_PATH "$tree/bin/modular-crashpad-handler" \
          --prefix PATH : "$out/toolchain-bin" \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}

        makeWrapper "$tree/bin/mojo-lsp-server" "$out/bin/mojo-lsp-server" \
          --set MODULAR_MAX_PACKAGE_ROOT "$tree" \
          --set MODULAR_MOJO_MAX_PACKAGE_ROOT "$tree" \
          --set MODULAR_MOJO_MAX_DRIVER_PATH "$tree/bin/mojo" \
          --set MODULAR_MOJO_MAX_IMPORT_PATH "$tree/lib/mojo" \
          --set MODULAR_MOJO_MAX_CRASHPAD_HANDLER_PATH "$tree/bin/modular-crashpad-handler" \
          --prefix PATH : "$out/toolchain-bin" \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}

        cat >"$out/bin/mojo-run" <<'EOF'
    #!${stdenv.shell}
    export LD_LIBRARY_PATH=${
      lib.makeLibraryPath [ stdenv.cc.cc.lib ]
    }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    exec "$@"
    EOF
        chmod +x "$out/bin/mojo-run"
  '';

  meta = {
    description = "Mojo 1.0.0 hermetic toolchain (pinned PyPI wheels, native payloads only)";
    homepage = "https://www.modular.com/mojo";
    license = lib.licenses.unfreeRedistributable;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}

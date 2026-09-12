{
  pkgs,
  lib,
  tsSource,
  xterm,
}:
let
  python = pkgs.python313;
  pscript = python.pkgs.pscript.overridePythonAttrs (_: {
    version = "0.8.1";
    postPatch = "";
    src = pkgs.fetchPypi {
      pname = "pscript";
      version = "0.8.1";
      hash = "sha256-04WL+bNEVK+AGMfquDLC9Kr1T4eNfkDzEx/23WNLzf0=";
    };
    doCheck = false;
  });
  webtypy = python.pkgs.buildPythonPackage {
    pname = "webtypy";
    version = "0.1.7";
    format = "wheel";
    src = pkgs.fetchPypi {
      pname = "webtypy";
      version = "0.1.7";
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-815tc6Tgh4PiOt+sJxoRzaOivREFSZ23DkgZJE7+0K4=";
    };
    doCheck = false;
  };
  compiler = python.withPackages (ps: [
    pscript
    webtypy
    ps.mypy
  ]);
  tsGenerator = pkgs.buildNpmPackage {
    pname = "ts-to-python";
    version = "0.1.8";
    src = "${tsSource}/type-generation";
    nodejs = pkgs.nodejs_24;
    npmDepsHash = "sha256-7FlQ0Ubinuy+zbasL6QnipDNPZzZ/XFkfzqs6/YMiAk=";
    dontNpmPrune = true;
    installPhase = ''
      mkdir -p "$out/lib"
      cp -R dist node_modules "$out/lib/"
    '';
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "latent-browser-host";
  version = "0.1.0";
  outputs = [
    "out"
    "types"
  ];
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../browser
      ../tools/browser_types.py
      ../pyproject.toml
    ];
  };
  nativeBuildInputs = [
    compiler
    pkgs.nodejs_24
  ];
  buildPhase = ''
    export HOME="$TMPDIR"
    mkdir -p input/node_modules "$types" "$out"
    python tools/browser_types.py prepare ${xterm}/types/xterm.d.ts ${xterm}/types/addon-fit.d.ts input
    ln -s ${tsGenerator}/lib/node_modules/typescript input/node_modules/typescript
    node ${tsGenerator}/lib/dist/main.js input generated.pyi
    python tools/browser_types.py generate ${webtypy}/${python.sitePackages}/js-stubs/__init__.pyi generated.pyi "$types"
    export MYPYPATH="$types"
    python tools/browser_types.py check
    python tools/browser_types.py transpile browser/host.py "$out/host.js"
  '';
  installPhase = "true";
  passthru = { inherit compiler; };
}

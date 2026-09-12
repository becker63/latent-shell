{ runCommand, fetchurl }:

let
  # Published browser bundles, fetched as immutable artifacts. No npm tooling
  # runs and no package.json participates in the application's dependency graph.
  xterm = fetchurl {
    url = "https://registry.npmjs.org/@xterm/xterm/-/xterm-5.5.0.tgz";
    hash = "sha256-vZVPpyGHIXAYjMXX6D6I2zyDyaGKTo0kwng9JkkfWdI=";
  };
  fit = fetchurl {
    url = "https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-0.10.0.tgz";
    hash = "sha256-kXrESXJFPV7tUu3B5QJgx2OYzkjPIpDC5gZxECu6CzM=";
  };
in
runCommand "latent-shell-xterm-5.5.0-fit-0.10.0" { } ''
  mkdir -p xterm fit "$out/licenses"
  tar -xf ${xterm} --strip-components=1 -C xterm
  tar -xf ${fit} --strip-components=1 -C fit
  cp xterm/lib/xterm.js "$out/xterm.js"
  cp xterm/css/xterm.css "$out/xterm.css"
  cp fit/lib/addon-fit.js "$out/xterm-fit.js"
  mkdir -p "$out/types"
  cp xterm/typings/xterm.d.ts "$out/types/xterm.d.ts"
  cp fit/typings/addon-fit.d.ts "$out/types/addon-fit.d.ts"
  cp xterm/LICENSE "$out/licenses/xterm"
  if test -f fit/LICENSE; then cp fit/LICENSE "$out/licenses/xterm-fit"; fi
''

{
  runCommand,
  fetchurl,
  python313,
}:
let
  catalog = fetchurl {
    url = "https://raw.githubusercontent.com/openai/codex/rust-v0.154.0/codex-rs/models-manager/models.json";
    hash = "sha256-87gQQ5ba9jgb7Z18SxVKhmT5tQibRLAanVT0IVZuyac=";
  };
in
runCommand "latent-codex-model-only-profile" { nativeBuildInputs = [ python313 ]; } ''
  mkdir -p "$out"
  python ${../tools/codex_catalog.py} ${catalog} "$out/models.json"
''

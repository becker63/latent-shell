# Latent Shell

Describe a computer. Watch its filesystem materialize in the terminal. Once the
world seals, explore it with a Unix-like shell: the model is gone after boot.

One authenticated, schema-constrained model call produces a bounded immutable
`WorldImage`. A self-contained Mojo/Wasm machine owns every subsequent command.
Pinned Toybox 0.8.13 supplies real `basename`, `dirname`, `cat`, and `head` applets.

Reality and knowledge are deliberately separate. `Knowledge` records what you
have observed; `rm` forgets that knowledge without deleting anything from the
image. A later `ls`, or even Tab completion, rediscovers it entirely locally.

Python imagines the computer. Mojo becomes the computer. Nix builds both.

## Run

Install and log in to Codex normally. Latent Shell reuses that authenticated
session through the official `openai-codex` Python SDK. The application never
reads or copies Codex authentication files.

```console
nix develop
uv sync --locked
uv run --locked uvicorn server.app:app --host 127.0.0.1 --port 8000
```

Open http://127.0.0.1:8000. A native dialog asks for the computer description;
submitting it opens xterm immediately for a provisional boot preview. Complete
paths from the actual model stream appear as a bounded tree, without displaying
file contents or model reasoning. The prompt becomes interactive only after
Python and Mojo accept the final image. Refresh starts a fresh world.

Tab completes commands and paths. Up/Down recall Mojo-owned history; Left/Right,
Home/End and Ctrl-A/E move the cursor. Ctrl-U/K delete before/after the cursor,
Ctrl-L clears the display, and Ctrl-C cancels a line or an unfinished generation.
Generation failure or cancellation returns to the description dialog without
retaining a partial computer.

Try `ls -lah`, `cd var`, `cat README`, `head -n 3 README`, `evidence`, and
`describe cat`. Paths vary with the generated world. After observing a path,
try `rm PATH`, `evidence`, then `ls` to see local rediscovery.

The SDK and its CLI runtime are locked to 0.154.0. Pydantic AI is pinned to
2.43.0, and the generation model is `gpt-5.6-terra`. Missing runtime,
authentication, or isolation profile fails startup clearly without exposing
credential details.

For browser sharing, bind Uvicorn to `0.0.0.0` behind an appropriate TLS reverse
proxy. The service limits requests to 10/minute and four concurrent generations
per process, with a 256 KiB input limit and a 90-second generation timeout.
Use one worker or enforce a shared
request limit at the proxy. This hackathon service has no user authentication.

## Authority

- `browser/host.py`: typed Python terminal, UTF-8/memory, and HTTP adaptation.
- `server/page.py`: the minimal HTML/CSS document, with no JavaScript blob.
- `server/world.py`: authoritative `File | Directory` generation contract,
  bounds, prompt, and single world agent.
- `server/codex_model.py`: a thin custom Pydantic AI Model over the Codex SDK.
- `server/boot.py`: provisional entry/tree events from actual output deltas.
- `shell/world.mojo`: immutable generated truth.
- `shell/knowledge.mojo`: mutable observed state.
- `shell/filesystem.mojo`: local access to truth while recording knowledge.
- `shell/userspace.mojo`: the narrow Mojo-to-Toybox argument/output boundary.
- `shell/commands.mojo` and `shell/shell.mojo`: temporary local utilities,
  shared command metadata, builtins, parsing, history, dispatch, and output.
- `shell/completion.mojo`: command catalog and filesystem completion. Directory
  enumeration records Knowledge just like `ls`.

One FastAPI-lifespan `AsyncCodex` transport serves the world agent. Every world
generation gets a new ephemeral thread and empty temporary cwd, with read-only sandboxing
and denied approvals. There is no retained Codex conversation between worlds.
Pydantic AI's requested native JSON Schema is passed directly to `output_schema`;
Pydantic validates the result and Mojo independently validates it before boot.
The Codex thread is then discarded; shell commands cannot call the model.
The agent permits one model request and no repair retry. Streaming clients send
`Accept: application/x-ndjson` to `POST /world`; ordinary clients receive a JSON
response. Provisional `start`, `reset`, `entry`, and `phase` events are presentation
only. A `complete` event carries the validated image; an `error` never seals it.

Disabling shell execution alone does not disable every Codex tool. The pinned
runtime's own model catalog is mechanically projected by `tools/codex_catalog.py`
to remove model-specific tool capabilities. That immutable Nix profile is used
alongside explicit disabled tool/MCP/plugin/skill-discovery settings. It is not a
second generation schema. The SDK alone handles authentication.

## Typed browser build

`nix build` derives the complete static runtime:

```text
shell.wasm
host.js
xterm.js
xterm.css
xterm-fit.js
```

The development shell supplies `LATENT_STATIC_DIR`, `LATENT_CODEX_CATALOG`, and
`MYPYPATH`. `LATENT_USERSPACE_LIB` and the pinned native runtime library path let
Mojo tests link the same Toybox bridge outside Wasm. Python serves the static files.

PScript 0.8.1 lowers Python source to standalone JavaScript. No Python interpreter
runs in the browser. Webtypy 0.1.7 supplies WebIDL-derived browser declarations;
the pinned xterm/Fit `.d.ts` files go through pinned `ts-to-python`. A generated
PScript shadow stub binds `window` to these foreign APIs. Small additional
protocols describe only the measured Mojo ABI and its memory/effect boundary.

The stub projection unwraps the upstream declaration modules and converts xterm
object-literal options to TypedDicts without maintaining a second xterm API.
Upstream generated declarations contain unrelated typing inconsistencies, so
mypy suppresses diagnostics inside that foreign module, not inside our host.
Build-time negative tests prove invalid DOM/xterm members and arguments fail.

Node/TypeScript are build-time dependencies of the upstream stub generator only.
There is no application package.json, npm state, frontend bundler, authored
TypeScript, tracked JavaScript, or Node runtime dependency. Generated JavaScript
and stubs live in Nix outputs, never Git.

Mojo 1.0.0 has no registered WASM target. `nix/wasm.nix` records the tested route:
generic x86-64 LLVM IR, LLVM textual compatibility translation, pinned LLVM 21
retargeting, then plain WASM64 linking. The final module has zero imports:
pinned wasi-libc dlmalloc owns allocation, LLVM compiler-rt owns `__multi3`, and
native IO resolves to guest-side traps. A tiny memory64 substrate grows bounded
linear memory from linker-provided heap symbols; it contains no allocation
policy. The browser fills one guest-owned input span with `TextEncoder.encodeInto`
and borrows Mojo's effect bytes until the next shell mutation. This is not WASI,
WASIX, or a VM. Chromium 148 is tested; WASM64 support is required.

## Shell and userspace limits

The interpreter remains the small Mojo parser, with quoting and backslash
escaping. Sequencing, variables, globbing, pipelines, loops, and redirection are
not supported. There is no writable overlay, process model, or destructive `rm`.

`cd`, `pwd`, `history`, `clear`, `help`, `commands`, `describe`, `evidence`, and
epistemic `rm` are builtins. `ls`, `stat`, and `wc` remain temporary Mojo utilities.
`describe COMMAND` reports the actual implementation and filesystem capabilities;
completion, help, and introspection share the same small command catalog. The
catalog remains a straightforward registry rather than a new reflection framework.

Toybox 0.8.13 is pinned at `a61f9fe68fafdabf2913b9498ce9ae1a086ed11d`.
Its four integrated applets run in-process with guest-side output capture.
`cat` supports `-e`, `-t`, `-u`, and `-v`; `head` supports line/byte counts with
`-n N` or `-c N`, plus `-q` and `-v`. This is a deliberately bounded adapter,
not a complete libc or full Toybox installation.

The pinned Toybox `toys/pending/sh.c` was inspected but not integrated. Its
in-process applet path still relies on non-local exit recovery and shared shell
state, while the interpreter also reaches fork/vfork, execve, signals, waitpid,
pipes/dup2, temporary files, and `/proc/self/fd`/`/proc/self/exe`. Providing those
facilities would exceed the small, zero-host-capability guest boundary.

WIT and generated Component Model bindings remain the long-term replacement for
the small core-WASM ABI. Pinned `wasm-tools` 1.256.0 embeds the interface but its
canonical lowering expects memory32 string pointers and cannot componentize this
memory64 module, so production deliberately stops at the simpler core module.

## Checks

```console
nix flake check
nix develop
uv sync --locked
uv run --locked pytest
python tools/browser_types.py check
uv run --locked python -m tests.generate_manifest
mojo build -I shell -I build -I "$MOJO_JSON_PATH" tests/test_shell.mojo -Xlinker "$LATENT_USERSPACE_LIB" -o build/test-shell
./build/test-shell
```

The Nix checks build actual WASM and the typed/transpiled host, enforce the source
law, and run cheap formatting/whitespace hooks. `nix develop` installs the hooks.
Normal tests use deterministic Pydantic AI models or fake Codex transports.
The native Mojo test is linked as an executable because `mojo run` does not link
the external Toybox archive through the tested JIT path.

For the offline browser smoke test, start this fixture server instead:

```console
uv run --locked uvicorn tests.fixture_server:app --host 127.0.0.1 --port 8000
```

In another development shell with Chromium available:

```console
uv run --locked python -m tests.browser_smoke --url http://127.0.0.1:8000
uv run --locked python -m tests.browser_boot --url http://127.0.0.1:8000
uv run --locked python -m tests.browser_boot --url http://127.0.0.1:8000 --cancel
```

Set `CHROMIUM` to the executable if necessary. The Python driver uses DevTools,
not Node. It covers the dialog, one `/world` request, xterm, real WASM, local
commands, completion and its Knowledge effects, history, middle-of-line editing,
Ctrl bindings, forgetting and local rediscovery, refresh, and mobile sizing.
The boot gate measures visible progress before the prompt and tests cancelling
one attempt before successfully booting another. Commands issue no later request.

The explicit live gate runs only against the production server with Codex login:

```console
uv run --locked python -m tests.browser_live --url http://127.0.0.1:8000
uv run --locked python -m tests.browser_boot --url http://127.0.0.1:8000
```

That gate has passed for the abandoned-university-supercomputer description. It
checks one structured world generation, Mojo validation, terminal output, and
local navigation and file access within the generated image.
One authenticated Chromium timing sample showed the first provisional entry at
28.619 seconds and the sealed prompt at 61.779 seconds, with 47 entry events.
These are measurements of one generation, not promised latency or fake progress.

## Source law

`tools/check_source_surface.py` checks sorted Git-tracked paths. Allowed extensions
are `.py`, `.mojo`, `.nix`, `.md`, and `.toml`; exact root metadata names are
`flake.lock`, `uv.lock`, `.gitignore`, and `LICENSE`. Every other tracked format
fails closed. Local hooks and Nix use the same policy. Generated assets, stubs,
hook configuration, and caches are untracked.

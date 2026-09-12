# Latent Shell

Build a browser-native shell for a computer that does not exist.

## Product

The page contains a full-screen terminal and one native dialog:

```text
Describe the computer you want to explore.
> _
```

Submitting the description closes the dialog and performs one bounded
world-generation request. Xterm displays a provisional, incrementally materialized
filesystem tree from actual model output. It becomes interactive only after
Python and Mojo have validated the final image. From then on, all command behavior
is local WebAssembly and the model is no longer involved.
Refresh creates a fresh session and independently generated world.

## Semantic model

```text
description
    -> one authenticated structured model call
    -> immutable finite WorldImage
    -> Mojo Filesystem
    -> local commands
```

`WorldImage` is what exists. It contains typed `File` and `Directory` entries with
normalized absolute paths and fully materialized bounded UTF-8 file contents. It
is immutable after boot.

`Knowledge` is what the user has observed. Filesystem operations learn structural
facts, reads, and inspections. `rm PATH` means `knowledge.forget(PATH)`: it does
not alter `WorldImage`. A later local `ls` can therefore rediscover the forgotten
path without model access. Path completion enumerates through the same filesystem
API and can also re-establish forgotten knowledge. Knowledge has one per-path
record containing kind, read, and inspection properties, not copies of file data.

Existence and knowledge are deliberately different concepts. There is an
authoritative generated reality after boot, but no real host filesystem beneath
it.

## Authority

Python owns the external generation contract, JSON Schema, Pydantic AI, the
authenticated Codex transport, HTTP policy, and the Python-authored browser host.
`server/world.py` expresses the complete product operation:
`WorldRequest -> WorldImage`.

Mojo owns `WorldImage` decoding and independent semantic validation, paths, cwd,
immutable filesystem lookup, mutable knowledge, parsing, command behavior,
history, completion, effects, and the browser ABI. JSON exists only at initialization and
output boundaries. Commands do not know about HTTP, models, or browser memory.

The browser host owns only the native dialog, xterm, line-editing mechanics,
provisional boot presentation, UTF-8 spans, Wasm loading, one `/world` transport,
and display of Mojo output. PScript lowers the authored
Python host to untracked JavaScript. Webtypy and the pinned xterm declarations
provide foreign-interface type evidence.

Nix pins and derives Mojo, the zero-import Wasm64 module, browser declarations,
generated host JavaScript, xterm assets, Codex isolation data, and the complete
static runtime. Project-authored implementation remains Python, Mojo, and Nix.

## World generation

`POST /world` accepts version 1 and a description of 1 to 2000 characters. It
returns version 1 and one `WorldImage` for ordinary JSON clients.
Clients accepting `application/x-ndjson` receive `start`, `reset`, `entry`, `phase`,
and finally `complete` or `error` events. `GET /manifest` exposes the Pydantic-derived
schema and bounds; it is a contract projection, not a command registry.

The result uses a discriminated union:

```text
WorldImage(entries)
    File(kind="file", path, contents)
    Directory(kind="directory", path)
```

Validation bounds entries, path bytes, depth, directory fanout, per-file bytes,
total content bytes, and serialized image bytes. Parents are derived where safe.
Duplicate paths, file descendants, invalid kinds, non-normal paths, and incoherent
contents fail before boot. Mojo independently enforces the semantic bounds before
accepting the image.

The current limits are 96 entries including derived parents, 512 UTF-8 bytes per
path, depth 8, 32 children per directory, 4096 bytes per file, 48 KiB of total
contents, and a 128 KiB serialized image. Root must be a directory.

Only complete individually valid entries from assistant output become provisional
preview events. Preview paths are deduplicated, sorted, and bounded to 18 visible
paths with an overflow count; visual parents may be derived. Contents and reasoning
are not displayed. The activity spinner represents waiting, never a percentage.
Restarted output resets the preview. Final Pydantic validation remains authoritative;
the preview never mutates Mojo. Mojo receives one final image and validates it
independently before a sealed prompt is shown.

The agent allows one model request and no repair retry. Failure or cancellation
does not produce a partial world or fall back to command-time generation.
Cancelling the streaming request cancels its producer and interrupts the SDK turn.

Pydantic AI forwards this same schema as native structured output to the custom
`CodexModel`. The official `openai-codex` SDK reuses an existing Codex login. Each
world uses a fresh ephemeral thread, empty temporary cwd, read-only sandbox,
denied approvals, no configured integrations, and a Nix-projected model catalog
without native tools. No Codex conversation survives world generation.

## Local computer

The current command surface is:

```text
basename cat cd clear commands describe dirname evidence
head help history ls pwd rm stat wc
```

`cd`, `pwd`, `history`, `clear`, `help`, `commands`, `describe`, `evidence`, and
epistemic `rm` are Latent Shell builtins. `basename`, `dirname`, `cat`, and `head`
execute the pinned Toybox 0.8.13 implementations inside Wasm. The current Mojo
implementations of `ls`, `stat`, and `wc` are deliberately small
temporary utilities and candidates for the same upstream-userspace boundary.

`describe COMMAND` projects implementation and filesystem capabilities from the
same semantic command catalog used for lookup and help. Commands access reality
only through `Filesystem`: resolve, lookup/stat, readdir, read, chdir, and forget.

No post-initialization operation can emit a model request. Browser acceptance
records exactly one `/world` request across navigation, listing, reading,
inspection, and epistemic forgetting.

Tab completes command names from the actual command catalog and paths through
`Filesystem.readdir`. Completion understands cwd, absolute/relative paths,
quoted/escaped tokens, Unicode, and the cursor position. Directories gain a slash;
`cd` completion filters to directories. Multiple matches extend the common prefix,
and a second Tab lists candidates. Directory enumeration is an observation.

Up/Down traverse Mojo-owned command history. Left/Right, Home/End, and Ctrl-A/E
move the editing cursor; Ctrl-U/K delete before/after it. Ctrl-L clears the display
and Ctrl-C cancels the current line, or aborts generation before seal. All editing,
completion, history, and command behavior is local once the world has sealed.

The interpreter is the Mojo quote/escape parser, not Toybox toysh or Bash.
Pipelines, sequencing, variables, loops, globbing, redirection, and a writable
overlay remain unsupported. Toysh's process and signal dependencies are outside
this closeout's bounded guest userspace.

## Wasm and security

The core Wasm64 module exports memory and a narrow UTF-8 span ABI:

```text
shell_init
shell_eval
shell_complete
shell_history
shell_input_ptr
shell_input_capacity
shell_result_ptr
shell_result_len
```

It has zero function imports. Pinned dlmalloc owns allocation, compiler-rt owns
LLVM arithmetic support, and unavailable native I/O resolves to guest-side traps.
Toybox file reads use a private guest adapter into the Mojo filesystem; its output
is captured in bounded guest memory, never forwarded to a host `write` import. The browser
does not implement an allocator, compiler runtime, filesystem, stdout, network,
WASI, WASIX, or a process model. The build fails if any Wasm import appears.

The server never executes terminal commands and never reads or copies Codex
authentication files. It applies body, rate, concurrency, and timeout limits and
sanitizes provider errors. Normal tests require no live model access.

## Acceptance invariants

- Exactly one model generation creates each world.
- Commands cause zero model requests.
- Actual streamed entries appear before the world is sealed; previews are not reality.
- Cancellation retains no partial session and interrupts the generation turn.
- `WorldImage` is immutable and `Knowledge` is mutable.
- `rm` forgets knowledge and local access can rediscover it.
- Completion is local and directory enumeration records Knowledge.
- Python owns the external schema; Mojo validates before boot.
- Browser code owns no shell semantics.
- Wasm has zero function imports.
- Refresh creates a new independent world.
- Nix is the build authority and the source-surface law remains fail-closed.

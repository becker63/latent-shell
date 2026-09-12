"""The one source-surface policy, shared by the local hook and Nix checks."""

import json
import subprocess
import sys
from pathlib import PurePosixPath

EXTENSIONS = frozenset({".py", ".mojo", ".nix", ".md", ".toml"})
METADATA = frozenset({"flake.lock", "uv.lock", ".gitignore", "LICENSE"})
ALLOWED = "implementation: .py .mojo .nix; documentation/config: .md .toml; exact root metadata: flake.lock uv.lock .gitignore LICENSE"


def rejected_paths(paths: list[bytes]) -> list[bytes]:
    rejected = []
    for raw in sorted(set(paths)):
        try:
            path = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            rejected.append(raw)
            continue
        if path not in METADATA and PurePosixPath(path).suffix not in EXTENSIONS:
            rejected.append(raw)
    return rejected


def main() -> int:
    try:
        root = (
            subprocess.run(
                ["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True
            )
            .stdout.decode()
            .strip()
        )
        result = subprocess.run(
            ["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        print(
            "source-surface: cannot enumerate tracked files; refusing to pass",
            file=sys.stderr,
        )
        return 1
    if not result or not result.endswith(b"\0"):
        print(
            "source-surface: empty or invalid Git index; refusing to pass",
            file=sys.stderr,
        )
        return 1
    rejected = rejected_paths(result[:-1].split(b"\0"))
    if rejected:
        print("source-surface: rejected tracked paths:", file=sys.stderr)
        for path in rejected:
            print(
                "  " + json.dumps(path.decode("utf-8", errors="backslashreplace")),
                file=sys.stderr,
            )
        print("Allowed surface: " + ALLOWED, file=sys.stderr)
        return 1
    print("source-surface: all tracked paths satisfy the allowed surface")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

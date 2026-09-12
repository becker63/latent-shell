"""Generate a test input from the authoritative Pydantic models, never a hand-written schema."""

import json
from pathlib import Path

from server.world import WorldImage, manifest

target = Path("build")
target.mkdir(exist_ok=True)
value = json.dumps(manifest(), separators=(",", ":"))
(target / "manifest.json").write_text(value)
(target / "manifest_fixture.mojo").write_text(
    "comptime IMAGE = "
    + json.dumps(
        json.dumps(
            WorldImage.model_validate(
                {
                    "entries": [
                        {
                            "path": "/README",
                            "kind": "file",
                            "contents": "Shutdown never completed.\n",
                        },
                        {"path": "/projects", "kind": "directory"},
                        {
                            "path": "/projects/notes.txt",
                            "kind": "file",
                            "contents": "one\ntwo\nthree\n",
                        },
                        {"path": "/moon", "kind": "directory"},
                        {"path": "/moon/door", "kind": "directory"},
                    ]
                }
            ).model_dump(mode="json"),
            separators=(",", ":"),
        )
    )
    + "\n"
)

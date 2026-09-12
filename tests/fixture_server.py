"""Explicit offline browser-test service. Never selected by production."""

import json
import asyncio

from pydantic_ai.messages import ModelResponse, TextPart
from pydantic_ai.models.function import FunctionModel

from server.app import create_app
from server.codex_model import output_progress

WORLD = {
    "entries": [
        {
            "path": "/README",
            "kind": "file",
            "contents": "This machine never shut down.\n",
        },
        {"path": "/scratch", "kind": "directory"},
        {"path": "/moon", "kind": "directory"},
        {
            "path": "/moon/console.log",
            "kind": "file",
            "contents": "The shutdown job never completed. café 東京 🚀\nsecond line\nthird line\n",
        },
        {"path": "/moon/door", "kind": "directory"},
        {"path": "/café-東京-🚀", "kind": "directory"},
        {"path": "/space directory", "kind": "directory"},
    ]
}


async def generate(messages, info):
    encoded = json.dumps(WORLD, ensure_ascii=False)
    progress = output_progress.get()
    if progress is not None:
        await progress(None)
        # Delays belong only to this fixture: make pre-seal behavior observable.
        for offset in range(0, len(encoded), 90):
            await progress(encoded[offset : offset + 90])
            await asyncio.sleep(0.12)
        await asyncio.sleep(0.4)
    return ModelResponse(parts=[TextPart(encoded)])


app = create_app(FunctionModel(generate))

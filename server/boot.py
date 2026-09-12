"""A provisional view of streamed JSON. Only WorldImage can seal reality."""

import asyncio
import json
import re
from contextlib import suppress

from pydantic import TypeAdapter, ValidationError

from .codex_model import generation_phase, output_progress
from .world import MAX_ENTRIES, MAX_IMAGE_BYTES, File, WorldEntry, generate_world


class Preview:
    def __init__(self, emit):
        self.emit = emit
        self.text = ""
        self.position = None
        self.entries = {}
        self.file_details = {}
        self.content_bytes = 0
        self.received_bytes = 0
        self.reported_bytes = 0
        self.decoder = json.JSONDecoder()
        self.entry_type = TypeAdapter(WorldEntry)

    async def delta(self, text):
        if text is None:
            self.text = ""
            self.position = None
            self.entries = {}
            self.file_details = {}
            self.content_bytes = 0
            self.received_bytes = 0
            self.reported_bytes = 0
            await self.emit({"type": "reset", "message": "receiving filesystem image"})
            return
        self.text += text
        self.received_bytes += len(text.encode("utf-8"))
        if self.received_bytes > MAX_IMAGE_BYTES:
            raise ValueError("generation exceeds image limit")
        if (
            self.reported_bytes == 0
            or self.received_bytes - self.reported_bytes >= 1024
        ):
            self.reported_bytes = self.received_bytes
            await self.emit({"type": "progress", "received_bytes": self.received_bytes})
        if self.position is None:
            start = re.match(r'\s*\{\s*"entries"\s*:\s*\[', self.text)
            if start is None:
                return
            self.position = start.end()

        while True:
            remaining = self.text[self.position :]
            skip = len(remaining) - len(remaining.lstrip(" \r\n\t,"))
            self.position += skip
            try:
                value, end = self.decoder.raw_decode(self.text, self.position)
            except ValueError:
                return
            self.position = end
            try:
                entry = self.entry_type.validate_python(value)
            except ValidationError:
                continue
            await self.learn(entry)

    async def learn(self, entry):
        if entry.path in self.entries:
            return
        if len(self.entries) >= MAX_ENTRIES:
            raise ValueError("generation exceeds entry limit")
        self.entries[entry.path] = entry.kind
        if isinstance(entry, File):
            size = len(entry.contents.encode("utf-8"))
            lines = entry.contents.count("\n")
            if entry.contents and not entry.contents.endswith("\n"):
                lines += 1
            self.file_details[entry.path] = (size, lines)
            self.content_bytes += size
        await self.emit(
            {
                "type": "entry",
                "path": entry.path,
                "kind": entry.kind,
                "count": len(self.entries),
                "files": len(self.file_details),
                "directories": len(self.entries) - len(self.file_details),
                "content_bytes": self.content_bytes,
                "received_bytes": self.received_bytes,
                "tree": self.tree(),
            }
        )

    def tree(self):
        """Bounded display projection, including unobserved visual parents."""
        paths = {"/": "directory", **self.entries}
        for path in tuple(paths):
            while path != "/":
                path = path.rsplit("/", 1)[0] or "/"
                paths.setdefault(path, "directory")
        lines = ["/"]
        ordered = sorted(path for path in paths if path != "/")
        visible = ordered[:18]
        for path in visible:
            pieces = path.strip("/").split("/")
            suffix = "/" if paths[path] == "directory" else ""
            detail = ""
            if path in self.file_details:
                size, count = self.file_details[path]
                detail = f"  [{size} B, {count} lines]"
            lines.append(
                "  " * (len(pieces) - 1) + "|- " + pieces[-1] + suffix + detail
            )
        if len(ordered) > len(visible):
            lines.append(f"... + {len(ordered) - len(visible)} more")
        return "\n".join(lines)


async def stream_world(agent, request, slots):
    queue = asyncio.Queue(maxsize=128)
    preview = Preview(queue.put)

    async def phase(message):
        await queue.put({"type": "phase", "message": message})

    async def produce():
        token = output_progress.set(preview.delta)
        phase_token = generation_phase.set(phase)
        try:
            await phase("waiting for a generation slot")
            async with slots, asyncio.timeout(90):
                await phase("preparing bounded world-generation request")
                image = await generate_world(agent, request)
                # Fake/non-streaming models still use the same final contract.
                for entry in image.entries:
                    await preview.learn(entry)
                await phase("world image validated; handing image to Mojo")
                await queue.put(
                    {"type": "complete", "image": image.model_dump(mode="json")}
                )
        except TimeoutError:
            await queue.put({"type": "error", "message": "world generation timed out"})
        except Exception:
            await queue.put({"type": "error", "message": "world generation failed"})
        finally:
            output_progress.reset(token)
            generation_phase.reset(phase_token)

    task = asyncio.create_task(produce())
    try:
        yield json.dumps({"type": "start", "message": "materializing machine"}) + "\n"
        while True:
            event = await queue.get()
            yield json.dumps(event, ensure_ascii=True) + "\n"
            if event["type"] in ("complete", "error"):
                break
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task

import asyncio
import json

from server.boot import Preview


def test_preview_requires_complete_entries_and_resets():
    async def run():
        events = []

        async def emit(event):
            events.append(event)

        preview = Preview(emit)
        fragment = '{"entries":[{"path":"/café/東京","kind":"file",'
        await preview.delta(fragment)
        assert events == [
            {"type": "progress", "received_bytes": len(fragment.encode("utf-8"))}
        ]
        assert preview.tree() == "/"
        await preview.delta('"contents":"hello 🚀"}')
        entries = [event for event in events if event["type"] == "entry"]
        assert len(entries) == 1
        assert entries[0]["path"] == "/café/東京"
        assert "café/" in entries[0]["tree"]
        assert "[10 B, 1 lines]" in entries[0]["tree"]
        assert entries[0]["content_bytes"] == 10
        assert entries[0]["files"] == 1
        assert entries[0]["directories"] == 0
        assert "hello" not in json.dumps(events)
        await preview.delta(
            ',{"path":"/café/東京","kind":"file","contents":"duplicate"}]}'
        )
        assert [event for event in events if event["type"] == "entry"] == entries
        await preview.delta(None)
        assert events[-1]["type"] == "reset"
        assert preview.tree() == "/"
        assert preview.content_bytes == 0
        assert preview.received_bytes == 0
        assert preview.file_details == {}

    asyncio.run(run())


def test_preview_never_displays_invalid_paths_or_contents():
    async def run():
        events = []

        async def emit(event):
            events.append(event)

        preview = Preview(emit)
        await preview.delta(
            json.dumps(
                {
                    "entries": [
                        {"path": "/bad\u001b[2J", "kind": "file", "contents": "hidden"},
                        {"path": "/good", "kind": "directory"},
                    ]
                }
            )
        )
        entries = [event for event in events if event["type"] == "entry"]
        assert [event["path"] for event in entries] == ["/good"]
        assert "hidden" not in json.dumps(events)
        assert "/bad" not in json.dumps(events)

    asyncio.run(run())


def test_progress_is_bounded_and_never_exposes_partial_contents():
    async def run():
        events = []

        async def emit(event):
            events.append(event)

        preview = Preview(emit)
        await preview.delta('{"entries":[{"path":"/notes","kind":"file","contents":"')
        for _ in range(200):
            await preview.delta("private")

        assert len(events) == 2
        assert all(event["type"] == "progress" for event in events)
        assert events[1]["received_bytes"] > events[0]["received_bytes"]
        assert preview.tree() == "/"
        assert "private" not in json.dumps(events)

    asyncio.run(run())

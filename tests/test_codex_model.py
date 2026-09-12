"""Offline tests at the real Pydantic AI / fake Codex SDK boundary."""

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from openai_codex import ApprovalMode, Sandbox
from openai_codex.generated.v2_all import TurnStatus
from pydantic_ai import models
from pydantic_ai.exceptions import UnexpectedModelBehavior

from server.app import create_app
from server.codex_model import (
    CodexModel,
    _codex_output_schema,
    authenticated_transport,
    transport_overrides,
)
from server.world import WorldImage, create_world_agent
from tests.test_server import WORLD, request
from tools.codex_catalog import generate


class FakeCodex:
    def __init__(self, result=None, failure=False):
        self.result = result or WORLD
        self.failure = failure
        self.threads = []
        self.turns = []
        self.interrupted = False

    async def thread_start(self, **kwargs):
        assert Path(kwargs["cwd"]).is_dir() and not tuple(Path(kwargs["cwd"]).iterdir())
        self.threads.append(kwargs)
        transport = self

        class Thread:
            async def turn(self, prompt, **options):
                transport.turns.append((prompt, options))
                return Turn()

        class Turn:
            async def stream(self):
                from openai_codex.models import Notification
                from openai_codex.generated.v2_all import (
                    AgentMessageDeltaNotification,
                    ItemCompletedNotification,
                    TurnCompletedNotification,
                )

                result = await self.run()
                text = result.final_response
                for offset in range(0, len(text), 7):
                    yield Notification(
                        "item/agentMessage/delta",
                        AgentMessageDeltaNotification(
                            delta=text[offset : offset + 7],
                            item_id="answer",
                            thread_id="thread",
                            turn_id="turn",
                        ),
                    )
                item = {"id": "answer", "type": "agentMessage", "text": text}
                yield Notification(
                    "item/completed",
                    ItemCompletedNotification.model_validate(
                        {
                            "item": item,
                            "threadId": "thread",
                            "turnId": "turn",
                            "completedAtMs": 1,
                        }
                    ),
                )
                yield Notification(
                    "turn/completed",
                    TurnCompletedNotification.model_validate(
                        {
                            "threadId": "thread",
                            "turn": {
                                "id": "turn",
                                "status": "completed",
                                "items": [item],
                            },
                        }
                    ),
                )

            async def run(self):
                if transport.failure:
                    raise RuntimeError("credential-like-provider-secret")
                text = (
                    transport.result
                    if isinstance(transport.result, str)
                    else json.dumps(transport.result)
                )
                return SimpleNamespace(
                    status=TurnStatus.completed,
                    error=None,
                    final_response=text,
                    items=[],
                )

            async def interrupt(self):
                transport.interrupted = True

        return Thread()


@pytest.fixture(autouse=True)
def fake_boundary_only(monkeypatch):
    monkeypatch.setattr(models, "ALLOW_MODEL_REQUESTS", False)
    monkeypatch.setattr(models, "check_allow_model_requests", lambda: None)


def test_pydantic_agent_forwards_world_schema():
    transport = FakeCodex()
    result = asyncio.run(
        create_world_agent(CodexModel(transport)).run("world description data")
    )
    assert result.output == WorldImage.model_validate(WORLD)
    prompt, options = transport.turns[0]
    assert json.loads(prompt)[0]["content"] == "world description data"

    def without_titles(value):
        if isinstance(value, dict):
            return {
                key: without_titles(item)
                for key, item in value.items()
                if key != "title"
            }
        if isinstance(value, list):
            return [without_titles(item) for item in value]
        return value

    assert without_titles(options["output_schema"]) == without_titles(
        _codex_output_schema(WorldImage.model_json_schema())
    )
    assert "oneOf" not in json.dumps(options["output_schema"])
    assert "discriminator" not in json.dumps(options["output_schema"])
    thread = transport.threads[0]
    assert thread["ephemeral"] is True
    assert thread["sandbox"] == Sandbox.read_only
    assert thread["approval_mode"] == ApprovalMode.deny_all
    assert not Path(thread["cwd"]).exists()


def test_requests_get_separate_ephemeral_threads():
    transport = FakeCodex()
    agent = create_world_agent(CodexModel(transport))

    async def run():
        await agent.run("first world")
        await agent.run("second world")

    asyncio.run(run())
    assert len(transport.threads) == 2
    assert transport.threads[0]["cwd"] != transport.threads[1]["cwd"]
    assert "first world" not in transport.turns[1][0]


@pytest.mark.parametrize("text", ["not JSON", "[]", '{"entries":"not a list"}'])
def test_malformed_output_fails(text):
    with pytest.raises(UnexpectedModelBehavior):
        asyncio.run(create_world_agent(CodexModel(FakeCodex(text))).run("world"))


def test_provider_failure_is_sanitized():
    with TestClient(create_app(CodexModel(FakeCodex(failure=True)))) as client:
        response = client.post("/world", json=request())
        assert response.status_code == 502
        assert response.json() == {"error": "world generation failed"}


def test_catalog_removes_model_specific_tools(tmp_path):
    source = tmp_path / "upstream.json"
    result = tmp_path / "generated.json"
    source.write_text(
        json.dumps(
            {"models": [{"slug": "example", "apply_patch_tool_type": "freeform"}]}
        )
    )
    generate(source, result)
    model = json.loads(result.read_text())["models"][0]
    assert (
        model["apply_patch_tool_type"] is None
        and model["experimental_supported_tools"] == []
    )
    assert "mcp_servers={}" in transport_overrides(result)


def test_auth_failure_is_clear_and_sanitized(monkeypatch, tmp_path):
    import openai_codex

    catalog = tmp_path / "models.json"
    catalog.write_text('{"models":[]}')
    monkeypatch.setenv("LATENT_CODEX_CATALOG", str(catalog))

    class Unauthenticated:
        def __init__(self, config):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def account(self):
            return SimpleNamespace(account=None)

    monkeypatch.setattr(openai_codex, "AsyncCodex", Unauthenticated)

    async def run():
        async with authenticated_transport():
            pytest.fail("unauthenticated transport was accepted")

    with pytest.raises(RuntimeError, match="login to Codex normally"):
        asyncio.run(run())


def test_cancellation_interrupts_sdk_turn():
    interrupted = []

    class Transport:
        async def thread_start(self, **kwargs):
            return self

        async def turn(self, *args, **kwargs):
            return self

        async def run(self):
            raise asyncio.CancelledError()

        async def interrupt(self):
            interrupted.append(True)

    with pytest.raises(asyncio.CancelledError):
        asyncio.run(create_world_agent(CodexModel(Transport())).run("world"))
    assert interrupted == [True]


def test_stream_forwards_schema_and_seals_once():
    transport = FakeCodex()
    with TestClient(create_app(CodexModel(transport))) as client:
        response = client.post(
            "/world", json=request(), headers={"Accept": "application/x-ndjson"}
        )
    events = [json.loads(line) for line in response.text.splitlines()]
    assert events[0]["type"] == "start"
    assert any(event["type"] == "entry" for event in events[:-1])
    assert events[-1]["type"] == "complete", events
    assert WorldImage.model_validate(events[-1]["image"])
    assert len(transport.threads) == len(transport.turns) == 1
    assert "output_schema" in transport.turns[0][1]


def test_stream_failure_never_seals_or_leaks_provider_details():
    with TestClient(create_app(CodexModel(FakeCodex(failure=True)))) as client:
        response = client.post(
            "/world", json=request(), headers={"Accept": "application/x-ndjson"}
        )
    events = [json.loads(line) for line in response.text.splitlines()]
    assert events[-1] == {"type": "error", "message": "world generation failed"}
    assert all(event["type"] != "complete" for event in events)
    assert "credential" not in response.text


def test_closing_world_stream_interrupts_turn_and_releases_slot():
    from openai_codex.generated.v2_all import AgentMessageDeltaNotification
    from openai_codex.models import Notification

    from server.boot import stream_world
    from server.world import WorldRequest

    class Transport:
        def __init__(self):
            self.interrupted = False
            self.cwd = None
            self.turn_count = 0

        async def thread_start(self, **options):
            self.cwd = Path(options["cwd"])
            assert self.cwd.is_dir()
            assert options["ephemeral"] is True
            return self

        async def turn(self, *args, **options):
            self.turn_count += 1
            return self

        async def stream(self):
            yield Notification(
                "item/agentMessage/delta",
                AgentMessageDeltaNotification(
                    delta='{"entries":[{"path":"/README","kind":"file","contents":"hello"}',
                    item_id="answer",
                    thread_id="thread",
                    turn_id="turn",
                ),
            )
            await asyncio.Event().wait()

        async def interrupt(self):
            self.interrupted = True

    async def run():
        transport = Transport()
        slots = asyncio.Semaphore(1)
        events = stream_world(
            create_world_agent(CodexModel(transport)),
            WorldRequest.model_validate(request()),
            slots,
        )
        observed = []
        try:
            async with asyncio.timeout(5):
                async for line in events:
                    event = json.loads(line)
                    observed.append(event["type"])
                    if event["type"] == "entry":
                        break
        finally:
            await events.aclose()

        assert "entry" in observed
        assert "complete" not in observed
        assert transport.turn_count == 1
        assert transport.interrupted
        assert not transport.cwd.exists()
        assert not slots.locked()

    asyncio.run(run())

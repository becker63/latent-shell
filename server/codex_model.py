"""Pydantic AI native output over one authenticated Codex SDK transport."""

import asyncio
import json
import os
from contextlib import asynccontextmanager
from contextvars import ContextVar
from pathlib import Path
from tempfile import TemporaryDirectory

from pydantic_ai import models
from pydantic_ai.exceptions import ModelHTTPError, UnexpectedModelBehavior
from pydantic_ai.messages import (
    InstructionPart,
    ModelRequest,
    ModelResponse,
    RetryPromptPart,
    SystemPromptPart,
    TextPart,
    UserPromptPart,
)
from pydantic_ai.models import Model, ModelRequestParameters
from pydantic_ai.settings import ModelSettings


# Scoped to an Agent invocation, so concurrent worlds cannot share previews.
output_progress = ContextVar("output_progress", default=None)
generation_phase = ContextVar("generation_phase", default=None)


async def report_phase(message: str) -> None:
    callback = generation_phase.get()
    if callback is not None:
        await callback(message)


async def collect_stream(turn, progress):
    """Consume the SDK's public notification stream; never forward reasoning."""
    from openai_codex import TurnResult
    from openai_codex.generated.v2_all import (
        AgentMessageDeltaNotification,
        ItemCompletedNotification,
        TurnCompletedNotification,
    )

    items = []
    completed = None
    final_text = None
    final_item = None
    size = 0
    async for event in turn.stream():
        payload = event.payload
        if isinstance(payload, AgentMessageDeltaNotification):
            # Each assistant message is its own JSON candidate. Reset the visual
            # accumulator if the provider starts another message in this turn.
            if payload.item_id != final_item:
                final_item = payload.item_id
                size = 0
                await progress(None)
            size += len(payload.delta.encode("utf-8"))
            if size > 128 * 1024:
                raise UnexpectedModelBehavior("Codex output exceeds limit")
            await progress(payload.delta)
        elif isinstance(payload, ItemCompletedNotification):
            item = payload.item
            if item.root.type not in {"userMessage", "agentMessage", "reasoning"}:
                await turn.interrupt()
                raise UnexpectedModelBehavior("Codex returned an unexpected tool item")
            items.append(item)
            if item.root.type == "agentMessage":
                phase = item.root.phase
                if phase is None or phase.value == "final_answer":
                    final_text = item.root.text
        elif isinstance(payload, TurnCompletedNotification):
            completed = payload.turn

    if completed is None:
        raise UnexpectedModelBehavior("Codex stream did not complete")
    return TurnResult(
        id=completed.id,
        status=completed.status,
        error=completed.error,
        started_at=completed.started_at,
        completed_at=completed.completed_at,
        duration_ms=completed.duration_ms,
        final_response=final_text,
        items=items,
        usage=None,
    )


def transport_overrides(catalog: Path) -> tuple[str, ...]:
    # The SDK has no no-tools thread option. Empty integrations plus a projected
    # model catalog remove both configured and model-native tool capabilities.
    return (
        "mcp_servers={}",
        "apps={}",
        "plugins={}",
        "hooks={}",
        "features.skip_host_skill_discovery=true",
        'web_search="disabled"',
        "tools.update_plan.enabled=false",
        "tools.experimental_request_user_input.enabled=false",
        "include_environment_context=false",
        "include_apps_instructions=false",
        "include_collaboration_mode_instructions=false",
        "project_doc_max_bytes=0",
        'developer_instructions=""',
        "model_catalog_json=" + json.dumps(str(catalog)),
    )


@asynccontextmanager
async def authenticated_transport():
    try:
        from openai_codex import AsyncCodex, CodexConfig
    except ImportError:
        raise RuntimeError(
            "Codex SDK/runtime is unavailable; run uv sync --locked"
        ) from None
    catalog = Path(
        os.environ.get("LATENT_CODEX_CATALOG", "build/codex-no-tools-models.json")
    )
    if not catalog.is_file():
        raise RuntimeError("Codex isolation profile is unavailable; enter nix develop")
    with TemporaryDirectory(prefix="latent-transport-") as cwd:
        codex = AsyncCodex(
            CodexConfig(
                cwd=cwd, config_overrides=transport_overrides(catalog.resolve())
            )
        )
        try:
            await codex.__aenter__()
            if (await codex.account()).account is None:
                raise RuntimeError("unauthenticated")
        except Exception:
            try:
                await codex.__aexit__(None, None, None)
            except Exception:
                pass
            raise RuntimeError(
                "Codex could not initialize an authenticated session; "
                "login to Codex normally"
            ) from None
        try:
            yield codex
        finally:
            await codex.__aexit__(None, None, None)


def _adapt_request(messages, params):
    if (
        params.function_tools
        or params.native_tools
        or params.output_tools
        or params.output_object is None
    ):
        raise UnexpectedModelBehavior(
            "Codex adapter requires native structured output without tools"
        )
    instructions = InstructionPart.join(params.instruction_parts or []) or ""
    transcript = []
    for message in messages:
        for part in message.parts:
            if isinstance(part, SystemPromptPart):
                instructions += "\n" + part.content
            elif isinstance(part, UserPromptPart) and isinstance(part.content, str):
                transcript.append({"role": "user", "content": part.content})
            elif isinstance(part, TextPart) and isinstance(message, ModelResponse):
                transcript.append({"role": "assistant", "content": part.content})
            elif isinstance(part, RetryPromptPart):
                transcript.append(
                    {"role": "user", "content": json.dumps(part.content, default=str)}
                )
            else:
                raise UnexpectedModelBehavior("Unsupported Codex adapter message")
        if (
            not params.instruction_parts
            and isinstance(message, ModelRequest)
            and message.instructions
        ):
            instructions = message.instructions
    return (
        instructions,
        transcript,
        _codex_output_schema(params.output_object.json_schema),
    )


def _codex_output_schema(value):
    """Project Pydantic unions into Codex's equivalent structured-output subset."""

    if isinstance(value, list):
        return [_codex_output_schema(item) for item in value]
    if not isinstance(value, dict):
        return value

    projected = {}
    for key, item in value.items():
        if key == "discriminator":
            continue
        projected_key = "anyOf" if key == "oneOf" else key
        projected[projected_key] = _codex_output_schema(item)
    return projected


def _validate_result(result, model_name: str) -> ModelResponse:
    if result.error is not None or result.status.value != "completed":
        raise UnexpectedModelBehavior("Codex inference did not complete")
    allowed_items = {"userMessage", "agentMessage", "reasoning"}
    if any(item.root.type not in allowed_items for item in result.items):
        raise UnexpectedModelBehavior("Codex returned an unexpected tool item")
    text = result.final_response
    if not isinstance(text, str) or len(text) > 65536:
        raise UnexpectedModelBehavior("Invalid Codex structured response")
    try:
        value = json.loads(text)
    except (ValueError, RecursionError):
        raise UnexpectedModelBehavior("Invalid Codex structured JSON") from None
    if not isinstance(value, dict):
        raise UnexpectedModelBehavior("Codex structured output must be an object")
    return ModelResponse(
        parts=[TextPart(text)], model_name=model_name, finish_reason="stop"
    )


class CodexModel(Model):
    def __init__(self, codex, model_name: str = "gpt-5.6-terra"):
        super().__init__(
            profile={
                "supports_json_schema_output": True,
                "supports_tools": False,
                "default_structured_output_mode": "native",
            }
        )
        self.codex = codex
        self._model_name = model_name

    @property
    def model_name(self) -> str:
        return self._model_name

    @property
    def system(self) -> str:
        return "openai"

    async def request(
        self,
        messages,
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse:
        models.check_allow_model_requests()
        _, params = self.prepare_request(model_settings, model_request_parameters)
        instructions, transcript, output_schema = _adapt_request(messages, params)
        from openai_codex import ApprovalMode, Sandbox

        with TemporaryDirectory(prefix="latent-world-") as cwd:
            try:
                await report_phase("opening isolated model session")
                thread = await self.codex.thread_start(
                    model=self.model_name,
                    ephemeral=True,
                    cwd=cwd,
                    sandbox=Sandbox.read_only,
                    approval_mode=ApprovalMode.deny_all,
                    base_instructions=instructions,
                )
                await report_phase("requesting structured filesystem image")
                turn = await thread.turn(
                    json.dumps(transcript), output_schema=output_schema
                )
                try:
                    await report_phase("model composing the image; waiting for output")
                    progress = output_progress.get()
                    if progress is None:
                        result = await turn.run()
                    else:
                        result = await collect_stream(turn, progress)
                except asyncio.CancelledError:
                    try:
                        await asyncio.wait_for(turn.interrupt(), timeout=2)
                    except Exception:
                        pass
                    raise
            except asyncio.CancelledError:
                raise
            except Exception:
                raise ModelHTTPError(
                    502, self.model_name, "Codex inference failed"
                ) from None
        await report_phase("validating structured output and filesystem")
        return _validate_result(result, self.model_name)

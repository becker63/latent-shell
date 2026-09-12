"""Only the measured Mojo ABI and browser effect envelope, never shell semantics."""

from typing import Any, Literal, Protocol, TypedDict


class OutputEffect(TypedDict):
    type: Literal["output", "error", "clear"]
    text: str
    prompt: str


Effect = OutputEffect


class Edit(TypedDict):
    line: str
    prefix: str
    candidates: list[str]


class Buffer(Protocol):
    @property
    def byteLength(self) -> int: ...


class Memory(Protocol):
    buffer: Buffer


class Exports(Protocol):
    memory: Memory

    def shell_input_ptr(self) -> int: ...
    def shell_input_capacity(self) -> int: ...
    def shell_init(self, address: int, length: int) -> int: ...
    def shell_eval(self, handle: int, address: int, length: int) -> None: ...
    def shell_complete(
        self, handle: int, address: int, length: int, cursor: int
    ) -> None: ...
    def shell_history(self, handle: int, offset: int) -> None: ...
    def shell_result_ptr(self, handle: int) -> int: ...
    def shell_result_len(self, handle: int) -> int: ...


class Instance(Protocol):
    exports: Exports


class WasmAPI(Protocol):
    async def compile(self, binary: Buffer) -> object: ...
    async def instantiate(
        self, module: object, imports: dict[str, object]
    ) -> Instance: ...


class Bytes(Protocol):
    length: int


class BytesConstructor(Protocol):
    def __call__(self, buffer: Buffer, offset: int, length: int) -> Bytes: ...


class BigIntConstructor(Protocol):
    def call(self, this: None, value: int) -> int: ...


class NumberConstructor(Protocol):
    def call(self, this: None, value: int) -> int: ...


class JSONAPI(Protocol):
    def stringify(self, value: object) -> str: ...
    # This is deliberately the untrusted JSON boundary. Mojo validates values.
    def parse(self, value: str) -> Any: ...

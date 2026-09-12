"""Generate once, then edit terminal lines and exchange UTF-8 spans with Mojo."""

from typing import Any, Callable

from pscript import Edit, Effect, Event, Exports, OutputEffect, TerminalOptions, window

MAX_EXCHANGE = 512 * 1024
TERMINAL_OPTIONS: TerminalOptions = {
    "fontFamily": "ui-monospace, monospace",
    "fontSize": 15,
    "lineHeight": 1.35,
    "cursorBlink": True,
    "cursorStyle": "block",
    "convertEol": True,
    "scrollback": 3000,
    "theme": {
        "background": "#fef7f0",
        "foreground": "#292524",
        "cursor": "#b45309",
        "selectionBackground": "#e7d8c9",
    },
}


def bigint(value: int) -> int:
    return window.BigInt.call(None, value)


def number(value: int) -> int:
    return window.Number.call(None, value)


class MojoShell:
    def __init__(self, wasm: Exports) -> None:
        self.wasm = wasm
        self.handle = bigint(0)
        self.encoder = window.TextEncoder()
        self.decoder = window.TextDecoder("utf-8", {"fatal": True})

    def exchange(
        self, text: str, invoke: Callable[[int, int], int | None]
    ) -> int | None:
        pointer = self.wasm.shell_input_ptr()
        capacity = self.wasm.shell_input_capacity()
        target = window.Uint8Array(self.wasm.memory.buffer, number(pointer), capacity)
        result = self.encoder.encodeInto(text, target)
        if result["read"] != len(text):
            raise ValueError("exchange exceeds size limit")
        return invoke(number(pointer), result["written"])

    def result(self) -> Any:
        length = self.wasm.shell_result_len(self.handle)
        if length > MAX_EXCHANGE:
            raise ValueError("shell effect exceeds size limit")
        pointer = self.wasm.shell_result_ptr(self.handle)
        encoded = window.Uint8Array(self.wasm.memory.buffer, number(pointer), length)
        return window.JSON.parse(self.decoder.decode(encoded))

    def initialize(self, image: object) -> Effect:
        encoded = window.JSON.stringify({"image": image})
        handle = self.exchange(encoded, self.wasm.shell_init)
        if handle is None or handle == bigint(0):
            raise ValueError("could not initialize shell")
        self.handle = handle
        return self.result()

    def eval(self, line: str) -> Effect:
        self.exchange(
            line,
            lambda pointer, length: self.wasm.shell_eval(self.handle, pointer, length),
        )
        return self.result()

    def complete(self, line: str, cursor: int) -> Edit | None:
        byte_cursor = self.encoder.encode(line[:cursor]).length
        self.exchange(
            line,
            lambda pointer, length: self.wasm.shell_complete(
                self.handle, pointer, length, byte_cursor
            ),
        )
        return self.result()

    def history(self, offset: int) -> Edit | None:
        self.wasm.shell_history(self.handle, offset)
        return self.result()


class BootView:
    def __init__(self, terminal: Any) -> None:
        self.terminal = terminal
        self.message = "materializing machine"
        self.tree = "/"
        self.steps: list[str] = []
        self.started = window.performance.now()
        self.files = 0
        self.directories = 0
        self.content_bytes = 0
        self.received_bytes = 0
        self.latest = ""
        self.tick = 0
        self.active = True
        self.painting = False
        self.repaint = False
        self.timer = window.setInterval(self.draw, 160)
        self.draw()

    def draw(self) -> None:
        if not self.active:
            return
        if self.painting:
            self.repaint = True
            return
        spinner = "|/-\\"[self.tick % 4]
        self.tick += 1
        elapsed = int((window.performance.now() - self.started) / 1000)
        lines = [spinner + " " + self.message + " (provisional)"]
        lines.append(
            str(elapsed)
            + "s elapsed | "
            + str(self.files)
            + " files | "
            + str(self.directories)
            + " directories | "
            + str(self.content_bytes)
            + " file bytes"
        )
        stream = str(self.received_bytes) + " structured-output bytes received"
        if self.latest:
            stream += " | latest: " + self.latest
        lines.append(stream)
        # Phase history is useful on a normal display, but the filesystem is the
        # primary boot artifact. On short terminals, give every spare row to it.
        if self.terminal.rows >= 18:
            for step in self.steps[-2:]:
                lines.append("  " + step)
        lines.append("")
        lines.append("filesystem preview:")
        tree = self.tree.split("\n")
        available = max(4, self.terminal.rows - len(lines) - 2)
        for line in tree[:available]:
            lines.append(line)
        if len(tree) > available:
            lines.append("... preview clipped to terminal height")
        lines.append("")
        lines.append("Preview only until validated. Ctrl-C cancels.")
        self.painting = True
        self.terminal.write(
            "\x1b[H\x1b[2J" + "\r\n".join(lines),
            self.painted,
        )

    def painted(self) -> None:
        self.painting = False
        if self.repaint:
            self.repaint = False
            self.draw()

    def phase(self, message: str) -> None:
        self.message = message
        elapsed = int((window.performance.now() - self.started) / 1000)
        self.steps.append(str(elapsed) + "s  " + message)
        self.steps = self.steps[-3:]
        self.draw()

    def event(self, event: Any) -> None:
        kind = event["type"]
        if kind == "reset":
            self.tree = "/"
            self.files = 0
            self.directories = 0
            self.content_bytes = 0
            self.received_bytes = 0
            self.latest = ""
            self.phase(event["message"])
            return
        elif kind == "entry":
            self.tree = event["tree"]
            self.files = event["files"]
            self.directories = event["directories"]
            self.content_bytes = event["content_bytes"]
            self.received_bytes = event["received_bytes"]
            self.latest = event["path"]
            self.message = str(event["count"]) + " objects materializing"
        elif kind == "progress":
            self.received_bytes = event["received_bytes"]
            self.message = "receiving filesystem and file contents"
        elif kind == "phase" or kind == "start":
            self.phase(event["message"])
            return
        self.draw()

    def stop(self) -> None:
        self.active = False
        self.repaint = False
        window.clearInterval(self.timer)

    def sealed(self, count: int) -> None:
        self.stop()
        self.terminal.write("\x1b[H\x1b[2J" + str(count) + " objects sealed\r\n\r\n")


async def generate_world(seed: str, boot: BootView, signal: Any) -> Any:
    response = await window.fetch(
        "/world",
        {
            "method": "POST",
            "headers": {
                "Content-Type": "application/json",
                "Accept": "application/x-ndjson",
            },
            "body": window.JSON.stringify({"version": 1, "seed": seed}),
            "signal": signal,
        },
    )
    if not response.ok or response.body is None:
        raise ValueError("world generation failed")
    reader = response.body.getReader()
    assert isinstance(reader, window.ReadableStreamDefaultReader)
    decoder = window.TextDecoder("utf-8", {"fatal": True})
    pending = ""
    while True:
        chunk = await reader.read()
        if chunk["done"]:
            break
        pending += decoder.decode(chunk["value"], {"stream": True})
        if len(pending) > MAX_EXCHANGE:
            raise ValueError("boot event exceeds limit")
        while "\n" in pending:
            split = pending.index("\n")
            event = window.JSON.parse(pending[:split])
            pending = pending[split + 1 :]
            if event["type"] == "complete":
                reader.releaseLock()
                return event["image"]
            if event["type"] == "error":
                raise ValueError("world generation failed")
            boot.event(event)
    raise ValueError("world stream ended before seal")


def previous(text: str, cursor: int) -> int:
    cursor = max(0, cursor - 1)
    if cursor > 0 and 0xDC00 <= ord(text[cursor]) <= 0xDFFF:
        cursor -= 1
    return cursor


def following(text: str, cursor: int) -> int:
    if cursor >= len(text):
        return len(text)
    if 0xD800 <= ord(text[cursor]) <= 0xDBFF:
        return min(len(text), cursor + 2)
    return cursor + 1


def columns(text: str) -> int:
    width = 0
    index = 0
    while index < len(text):
        code = ord(text[index])
        if 0xD800 <= code <= 0xDBFF and index + 1 < len(text):
            code = 0x10000 + (code - 0xD800) * 1024 + ord(text[index + 1]) - 0xDC00
        index = following(text, index)
        if 0x300 <= code <= 0x36F or code == 0x200D or 0xFE00 <= code <= 0xFE0F:
            continue
        if (
            0x1100 <= code <= 0x115F
            or 0x2E80 <= code <= 0xA4CF
            or 0xAC00 <= code <= 0xD7A3
            or 0xF900 <= code <= 0xFAFF
            or 0xFF01 <= code <= 0xFF60
            or 0x1F300 <= code <= 0x1FAFF
        ):
            width += 2
        else:
            width += 1
    return width


class Console:
    def __init__(self) -> None:
        element = window.document.querySelector("#terminal")
        assert isinstance(element, window.HTMLElement)
        self.terminal = window.Terminal(TERMINAL_OPTIONS)
        self.fit = window.FitAddon.FitAddon()
        self.terminal.loadAddon(self.fit)
        self.terminal.open(element)
        self.line = ""
        self.cursor = 0
        self.prompt = ""
        self.busy = True
        self.history_offset = 0
        self.draft = ""
        self.last_tab = False
        self.execute: Callable[[str], Any] = lambda line: None
        self.complete: Callable[[str, int], Any] = lambda line, cursor: None
        self.history: Callable[[int], Any] = lambda offset: None
        self.cancel: Callable[[], Any] = lambda: None
        self.observer = window.ResizeObserver(lambda entries, observer: self.resize())
        self.observer.observe(element)
        self.fit.fit()
        self.terminal.focus()
        self.terminal.onData(self.receive)

    def resize(self) -> None:
        self.fit.fit()
        if not self.busy:
            self.redraw()

    def ready(self) -> None:
        self.busy = False
        self.terminal.focus()

    def render(self, effect: OutputEffect) -> None:
        if effect["type"] == "clear":
            self.terminal.write("\x1b[H\x1b[2J\x1b[3J")
        self.prompt = effect["prompt"]
        self.terminal.write(effect["text"] + self.prompt, self.ready)

    def redraw(self) -> None:
        # Keep the editable viewport on one row, even for a long pasted line.
        prompt = self.prompt
        if columns(prompt) > self.terminal.cols - 10:
            prompt = "...$ "
        capacity = max(4, self.terminal.cols - columns(prompt) - 1)
        start = 0
        while columns(self.line[start : self.cursor]) >= capacity:
            start = following(self.line, start)
        end = self.cursor
        while end < len(self.line):
            next_end = following(self.line, end)
            if columns(self.line[start:next_end]) > capacity:
                break
            end = next_end
        visible = self.line[start:end]
        column = columns(prompt) + columns(self.line[start : self.cursor])
        self.terminal.write(
            "\r\x1b[2K" + prompt + visible + "\r\x1b[" + str(column + 1) + "G"
        )

    def recall(self, direction: int) -> None:
        if self.history_offset == 0:
            self.draft = self.line
        offset = max(0, self.history_offset + direction)
        if offset == 0:
            self.line = self.draft
        else:
            result = self.history(offset)
            if result is None or result["line"] == "":
                return
            self.line = result["line"]
        self.history_offset = offset
        self.cursor = len(self.line)
        self.redraw()

    def tab(self) -> None:
        result = self.complete(self.line, self.cursor)
        if result is None:
            return
        self.line = result["line"]
        self.cursor = len(result["prefix"])
        if self.last_tab and len(result["candidates"]) > 1:
            self.terminal.write("\r\n" + "  ".join(result["candidates"]) + "\r\n")
        self.last_tab = True
        self.redraw()

    async def receive(self, data: str, unused: None = None) -> None:
        if data == "\x03":
            if self.busy:
                self.cancel()
            else:
                self.line = ""
                self.cursor = 0
                self.history_offset = 0
                self.last_tab = False
                self.terminal.write("^C\r\n" + self.prompt)
            return
        if self.busy:
            return
        if data == "\t":
            self.tab()
            return
        self.last_tab = False
        if data == "\r":
            submitted = self.line
            self.line = ""
            self.cursor = 0
            self.history_offset = 0
            self.busy = True
            self.terminal.write("\r\x1b[2K" + self.prompt + submitted + "\r\n")
            try:
                await self.execute(submitted)
            except Exception:
                self.terminal.write("shell: runtime failure; refresh to restart\r\n")
            return
        if data == "\x1b[A" or data == "\x1b[B":
            self.recall(1 if data == "\x1b[A" else -1)
            return
        if data == "\x1b[D":
            self.cursor = previous(self.line, self.cursor)
        elif data == "\x1b[C":
            self.cursor = following(self.line, self.cursor)
        elif data in ["\x01", "\x1b[H", "\x1b[1~", "\x1bOH"]:
            self.cursor = 0
        elif data in ["\x05", "\x1b[F", "\x1b[4~", "\x1bOF"]:
            self.cursor = len(self.line)
        elif data == "\x15":
            self.line = self.line[self.cursor :]
            self.cursor = 0
        elif data == "\x0b":
            self.line = self.line[: self.cursor]
        elif data == "\x0c":
            self.terminal.write("\x1b[H\x1b[2J\x1b[3J")
        elif data == "\x7f":
            start = previous(self.line, self.cursor)
            self.line = self.line[:start] + self.line[self.cursor :]
            self.cursor = start
        elif data == "\x1b[3~":
            end = following(self.line, self.cursor)
            self.line = self.line[: self.cursor] + self.line[end:]
        elif data.startswith("\x1b"):
            return
        else:
            text = ""
            for char in data:
                if char in "\r\n\t":
                    text += " "
                elif ord(char) >= 32 and not 127 <= ord(char) <= 159:
                    text += char
            if len(self.line) + len(text) <= 4096:
                self.line = self.line[: self.cursor] + text + self.line[self.cursor :]
                self.cursor += len(text)
        self.redraw()


class Session:
    def __init__(self, console: Console, shell: MojoShell) -> None:
        self.console = console
        self.shell = shell
        console.execute = self.execute
        console.complete = shell.complete
        console.history = shell.history

    async def execute(self, line: str) -> None:
        self.console.render(self.shell.eval(line))


async def load_shell(image: object, boot: BootView) -> tuple[MojoShell, Effect]:
    boot.phase("loading self-contained Mojo/Wasm computer")
    response = await window.fetch("/static/shell.wasm")
    if not response.ok:
        raise ValueError("could not load shell")
    boot.phase("compiling WebAssembly module")
    module = await window.WebAssembly.compile(await response.arrayBuffer())
    boot.phase("initializing isolated guest memory and runtime")
    instance = await window.WebAssembly.instantiate(module, {})
    shell = MojoShell(instance.exports)
    boot.phase("Mojo independently validating the world image")
    return shell, shell.initialize(image)


async def launch(seed: str) -> None:
    console = Console()
    boot = BootView(console.terminal)
    controller = window.AbortController()
    console.cancel = lambda: controller.abort()
    try:
        image = await generate_world(seed, boot, controller.signal)
        shell, effect = await load_shell(image, boot)
        Session(console, shell)
        boot.sealed(len(image["entries"]))
        console.cancel = lambda: None
        console.render(effect)
    except Exception:
        boot.stop()
        controller.abort()
        console.terminal.dispose()
        console.observer.disconnect()
        dialog = window.document.querySelector("#world")
        assert isinstance(dialog, window.HTMLDialogElement)
        dialog.showModal()
        window.alert("World creation stopped. No world was sealed. Try again.")


def start() -> None:
    dialog = window.document.querySelector("#world")
    seed = window.document.querySelector("#seed")
    form = window.document.querySelector("form")
    assert isinstance(dialog, window.HTMLDialogElement)
    assert isinstance(seed, window.HTMLInputElement)
    assert form is not None

    async def submit(event: Event) -> None:
        event.preventDefault()
        if not seed.value.strip():
            return
        dialog.close()
        await launch(seed.value)

    form.addEventListener("submit", submit)
    dialog.addEventListener("cancel", lambda event: event.preventDefault())
    dialog.showModal()


start()

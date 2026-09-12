"""Generate, check, and lower the typed browser host.

No API signatures are scraped from prose or manually mirrored. Webtypy supplies
DOM/WebIDL signatures; ts-to-python supplies xterm signatures. Small ABI-only
contracts are authored separately. Generated stubs never execute in a browser.
"""

import argparse
import ast
import json
import re
import subprocess
import tempfile
from pathlib import Path


def prepare(xterm: Path, fit: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    parts = []
    for path in (xterm, fit):
        text = path.read_text()
        text = re.sub(r"^import .*?;\s*", "", text, flags=re.M)
        text, count = re.subn(r"declare module '[^']+' \{", "", text, count=1)
        if count != 1 or not text.rstrip().endswith("}"):
            raise ValueError("Upstream declaration module shape changed")
        parts.append(text.rstrip()[:-1])
    # Only unwrap the external-module containers. Every signature is upstream.
    (destination / "globals.d.ts").write_text("\n".join(parts))
    (destination / "tsconfig.json").write_text(
        json.dumps(
            {
                "compilerOptions": {
                    "target": "es2022",
                    "lib": ["ES2022", "DOM"],
                    "types": [],
                },
                "include": ["globals.d.ts"],
            }
        )
    )


def generate(webtypy: Path, xterm: Path, destination: Path) -> None:
    web = ast.parse(webtypy.read_text())
    terminal = ast.parse(xterm.read_text())
    web_names = {node.name for node in web.body if isinstance(node, ast.ClassDef)}
    classes = {
        node.name: node for node in terminal.body if isinstance(node, ast.ClassDef)
    }

    # ts-to-python emits option interfaces, while PScript lowers dict literals.
    # Preserve the generated fields but project those two object shapes to
    # TypedDict so mypy checks the Python literals passed to xterm.
    def options(name):
        node = classes[name]
        fields = []
        for base in node.bases:
            if isinstance(base, ast.Name) and base.id in classes:
                fields.extend(options(base.id).body)
        fields.extend(n for n in node.body if isinstance(n, ast.AnnAssign))
        fields = [n for n in fields if isinstance(n, ast.AnnAssign)]
        for field in fields:
            field.value = None
        return ast.ClassDef(
            name=name,
            bases=[ast.Name(id="TypedDict")],
            keywords=[ast.keyword(arg="total", value=ast.Constant(False))],
            body=fields or [ast.Pass()],
            decorator_list=[],
            type_params=[],
        )

    class Projection(ast.NodeTransformer):
        def visit_Subscript(self, node):
            if isinstance(node.value, ast.Name) and node.value.id in (
                "Uint8Array",
                "ArrayBuffer",
            ):
                return ast.Name(
                    id="Bytes" if node.value.id == "Uint8Array" else "Buffer"
                )
            return self.generic_visit(node)

        def visit_Name(self, node):
            if node.id in ("Uint8Array", "ArrayBuffer"):
                return ast.Name(id="Bytes" if node.id == "Uint8Array" else "Buffer")
            if node.id == "Function":
                return ast.parse("Callable[..., object]", mode="eval").body
            # Both generators see DOM declarations. Webtypy's WebIDL version is
            # authoritative, so xterm references are redirected to those names.
            if node.id.endswith("_iface") and node.id[:-6] in web_names:
                node.id = node.id[:-6]
            if node.id in ("false", "true"):
                return ast.Constant(node.id == "true")
            return node

    converted_options = {"Terminal__new__Sig0__options", "ITheme_iface"}
    nodes = list(web.body)
    for node in terminal.body:
        if isinstance(node, ast.ClassDef):
            if node.name in web_names or (
                node.name.endswith("_iface") and node.name[:-6] in web_names
            ):
                continue
            if node.name in converted_options:
                node = options(node.name)
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            if (
                isinstance(node, ast.ImportFrom)
                and node.module
                and ("pyodide" in node.module)
            ):
                continue
        nodes.append(node)
    # Webtypy and ts-to-python target Pyodide. PScript needs only static evidence,
    # so inert proxy bases replace runtime-only imports; API signatures survive.
    prelude = ast.parse("""
from typing import Any, Protocol, TypedDict, Callable, ClassVar, overload
from browser.contracts import Bytes, Buffer
class JsProxy: ...
class _JsProxyMetaClass(type): ...
class JsBuffer: ...
class JsArray[T](list[T]): ...
class JsIterable[T]: ...
class JsIterator[T]: ...
class JsGenerator[T, U, V]: ...
class JsAsyncIterator[T]: ...
class JsMutableMap[K, V]: ...
class ReadonlyMap[K, V]: ...
class PyodideFuture[T]: ...
""").body
    destination.mkdir(parents=True, exist_ok=True)
    foreign = ast.fix_missing_locations(
        Projection().visit(ast.Module(body=prelude + nodes, type_ignores=[]))
    )
    (destination / "foreign.pyi").write_text(ast.unparse(foreign) + "\n")
    package = destination / "pscript"
    package.mkdir(exist_ok=True)
    (package / "__init__.pyi").write_text(
        """
from foreign import Window, HTMLDialogElement, HTMLInputElement, HTMLElement, Event, ReadableStreamDefaultReader
from foreign import (TextEncoder, TextDecoder, ResizeObserver, AbortController, Terminal,
    Terminal__new__Sig0__options as TerminalOptions, FitAddon, Uint8Array)
from browser.contracts import (Edit, Effect, OutputEffect, Exports, Memory, Buffer, Bytes,
    BytesConstructor, BigIntConstructor, NumberConstructor, JSONAPI, WasmAPI)

class FitNamespace:
    FitAddon = staticmethod(FitAddon.new)

class LatentWindow(Window):
    Terminal = staticmethod(Terminal.new)
    FitAddon: FitNamespace
    HTMLDialogElement: type[HTMLDialogElement]
    HTMLInputElement: type[HTMLInputElement]
    HTMLElement: type[HTMLElement]
    ReadableStreamDefaultReader: type[ReadableStreamDefaultReader]
    TextEncoder = staticmethod(TextEncoder.new)
    TextDecoder = staticmethod(TextDecoder.new)
    ResizeObserver = staticmethod(ResizeObserver.new)
    AbortController = staticmethod(AbortController.new)
    WebAssembly: WasmAPI
    Uint8Array: BytesConstructor
    BigInt: BigIntConstructor
    Number: NumberConstructor
    JSON: JSONAPI

window: LatentWindow
__all__ = ['window', 'AbortController', 'Edit', 'Effect', 'OutputEffect', 'Event', 'Exports',
    'Memory', 'TerminalOptions']
""".lstrip()
    )


def check() -> None:
    command = ["mypy", "--config-file", "pyproject.toml"]
    subprocess.run([*command, "browser/host.py"], check=True)
    invalid = [
        ("window.document.querySelector(42)", "arg-type"),
        ("window.document.missingBrowserMethod()", "attr-defined"),
        ("window.Terminal().write(42)", "arg-type"),
        ("window.Terminal().missingTerminalMethod()", "attr-defined"),
    ]
    with tempfile.TemporaryDirectory() as directory:
        for index, (statement, diagnostic) in enumerate(invalid):
            source = Path(directory) / f"negative_{index}.py"
            source.write_text("from pscript import window\n" + statement + "\n")
            result = subprocess.run(
                [*command, str(source)], capture_output=True, text=True
            )
            if result.returncode != 1 or f"[{diagnostic}]" not in result.stdout:
                raise RuntimeError(
                    f"Foreign type evidence failed: {statement}\n{result.stdout}{result.stderr}"
                )
    print("PASS: DOM and xterm reject invalid members and argument types")


def transpile(source: Path, output: Path) -> None:
    from pscript import py2js

    output.write_text(str(py2js(source.read_text())) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "operation", choices=["prepare", "generate", "check", "transpile"]
    )
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()
    if args.operation == "prepare":
        prepare(*args.paths)
    elif args.operation == "generate":
        generate(*args.paths)
    elif args.operation == "check":
        if args.paths:
            parser.error("check takes no paths")
        check()
    elif len(args.paths) == 2:
        transpile(*args.paths)
    else:
        parser.error("transpile requires SOURCE OUTPUT")

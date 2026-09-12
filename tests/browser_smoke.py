"""Run the deterministic black-box browser checks against the Python host.

Start tests.fixture_server, then run with --url pointing at either host.
Uses Chromium's DevTools protocol directly; no Node or browser-driver bundle.
"""

import argparse
import json
import os
import selectors
import signal
import subprocess
import tempfile
import time
from contextlib import contextmanager

from websockets.sync.client import connect


class Browser:
    def __init__(self, socket):
        self.socket = socket
        self.sequence = 0
        self.session = None
        target = self.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        self.session = self.call(
            "Target.attachToTarget", {"targetId": target, "flatten": True}
        )["sessionId"]
        self.call("Page.enable")
        self.call("Runtime.enable")

    def call(self, method, params=None):
        self.sequence += 1
        message = {"id": self.sequence, "method": method, "params": params or {}}
        if self.session:
            message["sessionId"] = self.session
        self.socket.send(json.dumps(message))
        while True:
            response = json.loads(self.socket.recv(timeout=15))
            if response.get("id") == self.sequence:
                if "error" in response:
                    raise AssertionError(response["error"])
                return response["result"]

    def evaluate(self, expression):
        result = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": True,
                "returnByValue": True,
            },
        )
        if "exceptionDetails" in result:
            raise AssertionError(result["exceptionDetails"])
        return result["result"].get("value")

    def wait(self, expression, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.evaluate(expression):
                return
            time.sleep(0.05)
        raise AssertionError(
            f"Browser condition timed out: {expression}\n{self.text()}"
        )

    def key(self, key, code, number, text="", modifiers=0):
        self.call(
            "Input.dispatchKeyEvent",
            {
                "type": "keyDown",
                "key": key,
                "code": code,
                "windowsVirtualKeyCode": number,
                "text": text,
                "modifiers": modifiers,
            },
        )
        self.call(
            "Input.dispatchKeyEvent",
            {
                "type": "keyUp",
                "key": key,
                "code": code,
                "windowsVirtualKeyCode": number,
                "modifiers": modifiers,
            },
        )

    def enter(self, line):
        self.call("Input.insertText", {"text": line})
        self.key("Enter", "Enter", 13, "\r")
        self.settle()

    def settle(self):
        self.evaluate(
            "new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))"
        )

    def text(self):
        return self.evaluate(
            "document.querySelector('.xterm-rows')?.textContent || document.body.innerText"
        )

    def ready(self, path="/"):
        prompt = "guest@latent:" + path + "$"
        self.wait(
            f"document.querySelector('.xterm-rows')?.textContent.trimEnd().endsWith({json.dumps(prompt)})"
        )
        self.settle()


@contextmanager
def chromium():
    with tempfile.TemporaryDirectory(
        prefix="latent-browser-", ignore_cleanup_errors=True
    ) as profile:
        process = subprocess.Popen(
            [
                os.environ.get("CHROMIUM", "chromium"),
                "--headless=new",
                "--disable-gpu",
                "--no-sandbox",
                "--no-first-run",
                "--remote-debugging-port=0",
                f"--user-data-dir={profile}",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            selector = selectors.DefaultSelector()
            selector.register(process.stderr, selectors.EVENT_READ)
            deadline = time.monotonic() + 15
            endpoint = None
            while time.monotonic() < deadline:
                if selector.select(timeout=1):
                    line = process.stderr.readline()
                    if "DevTools listening on " in line:
                        endpoint = line.split("DevTools listening on ", 1)[1].strip()
                        break
                if process.poll() is not None:
                    raise AssertionError("Chromium exited before DevTools started")
            selector.close()
            if endpoint is None:
                raise AssertionError("Chromium did not start")
            with connect(endpoint, max_size=8 * 1024 * 1024) as socket:
                yield Browser(socket)
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            process.stderr.close()


TRACE = r"""
window.worldRequests = [];
window.alertMessage = null;
window.alert = message => { window.alertMessage = message; };
window.addEventListener('error', event => { window.browserError = event.message; });
window.addEventListener('unhandledrejection', event => {
  window.browserError = String(event.reason);
});
const originalFetch = window.fetch.bind(window);
window.fetch = async (...args) => {
  if (args[0] !== '/world') return originalFetch(...args);
  const trace = {request: JSON.parse(args[1].body), done: false, response: null};
  window.worldRequests.push(trace);
  let response;
  try {
    response = await originalFetch(...args);
  } catch (error) {
    trace.error = String(error);
    trace.aborted = args[1].signal?.aborted === true;
    trace.finished = performance.now();
    trace.done = true;
    throw error;
  }
  trace.started = performance.now();
  trace.events = [];
  (async () => {
    try {
    if (response.headers.get('content-type')?.includes('ndjson')) {
      const reader = response.clone().body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        buffer += decoder.decode(chunk.value, {stream: true});
        while (buffer.includes('\n')) {
          const index = buffer.indexOf('\n');
          const event = JSON.parse(buffer.slice(0, index));
          buffer = buffer.slice(index + 1);
          trace.events.push(event);
          if (event.type === 'entry' && !trace.firstEntry) trace.firstEntry = performance.now();
          if (event.type === 'complete') trace.response = event;
        }
      }
    } else trace.response = await response.clone().json();
    } catch (error) {
      trace.error = String(error);
      trace.aborted = args[1].signal?.aborted === true;
      if (!trace.aborted) window.browserError = trace.error;
    } finally {
      trace.finished = performance.now();
      trace.done = true;
    }
  })();
  return response;
};
"""


def run(url):
    with chromium() as browser:
        browser.call("Page.addScriptToEvaluateOnNewDocument", {"source": TRACE})
        browser.call("Page.navigate", {"url": url})
        browser.wait("document.readyState === 'complete'")
        browser.wait("document.querySelector('#seed') !== null")
        assert (
            browser.evaluate("document.querySelector('label').textContent")
            == "Describe the computer you want to explore."
        )
        assert not browser.evaluate("document.querySelector('.xterm') !== null")

        browser.evaluate(
            "document.querySelector('#seed').value = "
            "'an abandoned university machine'; "
            "document.querySelector('form').requestSubmit()"
        )
        browser.wait("worldRequests[0]?.events?.some(e => e.type === 'entry')")
        assert browser.evaluate("worldRequests[0].done") is False
        browser.wait(
            "document.querySelector('.xterm-rows')?.textContent.includes('provisional')"
        )
        browser.enter("pwd")
        assert "guest@latent:" not in browser.text()
        browser.wait("worldRequests.length === 1 && worldRequests[0].done")
        browser.wait(
            "document.querySelector('.xterm') !== null || "
            "Boolean(window.alertMessage) || Boolean(window.browserError)"
        )
        alert_message = browser.evaluate("window.alertMessage")
        browser_error = browser.evaluate("window.browserError")
        assert not alert_message, alert_message or browser_error
        browser.ready()
        assert browser.evaluate("worldRequests[0].request.seed") == (
            "an abandoned university machine"
        )

        browser.enter("pwd")
        browser.ready()
        assert browser.evaluate("worldRequests.length") == 1

        browser.call("Input.insertText", {"text": "pw"})
        browser.key("Tab", "Tab", 9, "\t")
        browser.key("Enter", "Enter", 13, "\r")
        browser.ready()
        browser.key("ArrowUp", "ArrowUp", 38)
        browser.wait(
            "document.querySelector('.xterm-rows').textContent.trimEnd().endsWith('$ pwd')"
        )
        browser.key("ArrowDown", "ArrowDown", 40)
        browser.ready()
        browser.call("Input.insertText", {"text": "cd mo"})
        browser.key("Tab", "Tab", 9, "\t")
        browser.key("Enter", "Enter", 13, "\r")
        browser.ready("/moon")
        browser.enter("rm door")
        browser.ready("/moon")
        browser.call("Input.insertText", {"text": "cd do"})
        browser.key("Tab", "Tab", 9, "\t")
        browser.key("c", "KeyC", 67, "\x03", modifiers=2)
        browser.enter("evidence")
        browser.ready("/moon")
        assert "/moon/door" in browser.text()
        browser.enter("cd /")
        browser.ready()

        browser.call("Input.insertText", {"text": "pxd"})
        browser.key("ArrowLeft", "ArrowLeft", 37)
        browser.key("Backspace", "Backspace", 8)
        browser.call("Input.insertText", {"text": "w"})
        browser.key("ArrowRight", "ArrowRight", 39)
        browser.key("Enter", "Enter", 13, "\r")
        browser.ready()
        browser.call("Input.insertText", {"text": "junk"})
        browser.key("u", "KeyU", 85, "\x15", modifiers=2)
        browser.ready()
        browser.call("Input.insertText", {"text": "discard"})
        browser.key("a", "KeyA", 65, "\x01", modifiers=2)
        browser.key("k", "KeyK", 75, "\x0b", modifiers=2)
        browser.ready()
        browser.call("Input.insertText", {"text": "pwd"})
        browser.key("a", "KeyA", 65, "\x01", modifiers=2)
        browser.key("e", "KeyE", 69, "\x05", modifiers=2)
        browser.key("l", "KeyL", 76, "\x0c", modifiers=2)
        browser.key("Enter", "Enter", 13, "\r")
        browser.ready()
        browser.call("Input.insertText", {"text": "cd café"})
        browser.key("Tab", "Tab", 9, "\t")
        browser.key("Enter", "Enter", 13, "\r")
        browser.ready("/café-東京-🚀")
        browser.enter("cd /")
        browser.ready()

        abi = browser.evaluate(
            """(async () => {
                const image = worldRequests[0].response.image;
                const phases = [];
                const pair = await load_shell(image, {phase: message => phases.push(message)});
                const shell = pair[0];
                const changed = shell.eval('cd café-東京-🚀');
                const near = shell.eval('x'.repeat(512 * 1024 - 1));
                let overflow = false;
                try {
                    shell.eval('x'.repeat(512 * 1024 + 1));
                } catch (error) {
                    overflow = true;
                }
                return {
                    phases: phases.length,
                    prompt: changed.prompt,
                    near: near.type,
                    overflow,
                };
            })()"""
        )
        assert abi == {
            "phases": 4,
            "prompt": "guest@latent:/café-東京-🚀$ ",
            "near": "error",
            "overflow": True,
        }

        browser.enter("ls")
        browser.ready()
        assert "README" in browser.text() and "scratch/" in browser.text()
        browser.enter("ls -lah")
        browser.ready()
        assert "drwxr-xr-x" in browser.text()
        browser.enter("cd moon")
        browser.ready("/moon")
        browser.enter("ls -S")
        browser.ready("/moon")
        browser.enter("cat console.log")
        browser.ready("/moon")
        assert "The shutdown job never completed. café 東京 🚀" in browser.text()
        browser.enter("head -n 2 console.log")
        browser.ready("/moon")
        browser.enter("wc -l console.log")
        browser.ready("/moon")
        browser.enter("stat console.log")
        browser.ready("/moon")
        browser.enter("evidence")
        browser.ready("/moon")
        assert "/moon/console.log" in browser.text()

        browser.enter("rm door")
        browser.ready("/moon")
        browser.enter("evidence")
        browser.ready("/moon")
        doors_before_rediscovery = browser.text().count("door/")
        browser.enter("ls")
        browser.ready("/moon")
        assert browser.text().count("door/") > doors_before_rediscovery
        assert browser.evaluate("worldRequests.length") == 1

        browser.key("c", "KeyC", 67, "\x03", modifiers=2)
        browser.ready("/moon")
        browser.call("Input.insertText", {"text": "pwxx"})
        browser.key("Backspace", "Backspace", 8)
        browser.key("Backspace", "Backspace", 8)
        browser.call("Input.insertText", {"text": "d"})
        browser.key("Enter", "Enter", 13, "\r")
        browser.ready("/moon")
        assert "command not found" not in browser.text()

        browser.call(
            "Emulation.setDeviceMetricsOverride",
            {
                "width": 390,
                "height": 844,
                "deviceScaleFactor": 1,
                "mobile": True,
            },
        )
        browser.call("Page.reload")
        browser.wait("document.querySelector('#seed') !== null")
        browser.wait("document.readyState === 'complete'")
        browser.settle()
        assert not browser.evaluate("document.querySelector('.xterm') !== null")
        browser.evaluate(
            "document.querySelector('#seed').value = 'a fresh world'; "
            "document.querySelector('form').requestSubmit()"
        )
        browser.wait("worldRequests.length === 1 && worldRequests[0].done")
        browser.ready()
        browser.enter("ls")
        browser.ready()
        assert browser.evaluate("worldRequests.length") == 1
        assert browser.evaluate("worldRequests[0].request.seed") == "a fresh world"
        assert browser.evaluate(
            "document.documentElement.scrollWidth <= window.innerWidth"
        )

    print(
        json.dumps(
            {
                "status": "PASS",
                "url": url,
                "world_generation_requests": 1,
                "command_time_model_requests": 0,
                "checks": [
                    "prompt",
                    "one WorldImage generation",
                    "xterm after generation",
                    "Mojo validation",
                    "local pwd/ls/cd/cat/stat/head/wc",
                    "Unix flags",
                    "UTF-8 guest span ABI",
                    "typed knowledge",
                    "local rm rediscovery",
                    "Ctrl-C line cancellation",
                    "tail editing",
                    "fresh world on refresh",
                    "mobile fit",
                ],
            }
        )
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    run(parser.parse_args().url)

"""Measure real boot progress in Chromium, using the existing browser harness."""

import argparse
import json

from tests.browser_smoke import TRACE, chromium


def run(url: str) -> dict:
    with chromium() as browser:
        browser.call("Page.addScriptToEvaluateOnNewDocument", {"source": TRACE})
        browser.call("Page.navigate", {"url": url})
        browser.wait('document.querySelector("#world")?.open')
        browser.call(
            "Input.insertText",
            {
                "text": (
                    "an abandoned university supercomputer "
                    "that has been running since 1998"
                )
            },
        )
        started = browser.evaluate("performance.now()")
        browser.key("Enter", "Enter", 13, "\r")

        browser.wait(
            "window.worldRequests?.[0]?.firstEntry && "
            'document.querySelector(".xterm-screen")?.textContent.includes("provisional")',
            timeout=110,
        )
        first_visible = browser.evaluate("performance.now()")
        assert browser.evaluate(
            "!worldRequests[0].done && "
            '!document.querySelector(".xterm-screen").textContent.includes("guest@latent:")'
        ), "The provisional tree must appear before the shell becomes interactive"

        browser.wait(
            'document.querySelector(".xterm-screen")?.textContent.includes("guest@latent:/$")',
            timeout=110,
        )
        sealed = browser.evaluate("performance.now()")
        for command in ("pwd", "cd /", "ls", "commands", "describe cat"):
            browser.enter(command)
            browser.ready()

        trace = browser.evaluate(
            "({count: worldRequests.length, request: worldRequests[0], "
            "error: window.browserError || null})"
        )
        assert trace["count"] == 1, "Commands must not generate another world"
        assert trace["error"] is None, trace["error"]
        request = trace["request"]
        events = request["events"]
        event_types = {event["type"] for event in events}
        assert {"start", "entry", "phase", "complete"} <= event_types
        assert request["done"] and request["response"] is not None

        return {
            "status": "PASS",
            "url": url,
            "world_generation_requests": trace["count"],
            "command_time_model_requests": 0,
            "first_entry_received_seconds": round(
                (request["firstEntry"] - started) / 1000, 3
            ),
            "first_entry_visible_seconds": round((first_visible - started) / 1000, 3),
            "sealed_prompt_visible_seconds": round((sealed - started) / 1000, 3),
            "preview_seen_before_seal": True,
            "event_types": sorted(event_types),
            "entry_events": sum(event["type"] == "entry" for event in events),
        }


def cancel(url: str) -> dict:
    """Cancel a provisional world, then boot a fresh one on the same page."""
    with chromium() as browser:
        browser.call("Page.addScriptToEvaluateOnNewDocument", {"source": TRACE})
        browser.call(
            "Page.addScriptToEvaluateOnNewDocument",
            {"source": "window.alert = message => { window.bootNotice = message; };"},
        )
        browser.call("Page.navigate", {"url": url})
        browser.wait('document.querySelector("#world")?.open')
        browser.call("Input.insertText", {"text": "a computer whose boot is cancelled"})
        browser.key("Enter", "Enter", 13, "\r")
        browser.wait("window.worldRequests?.[0]?.firstEntry", timeout=110)
        assert browser.evaluate("!worldRequests[0].done")

        browser.key("c", "KeyC", 67, modifiers=2)
        browser.wait('document.querySelector("#world")?.open')
        browser.wait("worldRequests[0].done")
        assert browser.evaluate("worldRequests[0].aborted === true")
        assert browser.evaluate("worldRequests[0].response === null")
        assert browser.evaluate("window.bootNotice.includes('No world was sealed')")
        assert not browser.evaluate(
            'document.querySelector(".xterm-screen")?.textContent.includes("guest@latent:")'
        )

        browser.key("a", "KeyA", 65, modifiers=2)
        browser.call(
            "Input.insertText", {"text": "a fresh computer after cancellation"}
        )
        browser.key("Enter", "Enter", 13, "\r")
        browser.wait("worldRequests.length === 2 && worldRequests[1].done", timeout=110)
        browser.ready()
        browser.enter("pwd")
        browser.ready()
        assert browser.evaluate("worldRequests.length") == 2
        assert browser.evaluate("worldRequests[1].response !== null")
        assert not browser.evaluate("window.browserError")
        return {
            "status": "PASS",
            "url": url,
            "cancelled_attempts": 1,
            "sealed_worlds": 1,
            "partial_session_retained": False,
            "command_time_model_requests": 0,
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument(
        "--cancel", action="store_true", help="test cancellation and retry"
    )
    arguments = parser.parse_args()
    operation = cancel if arguments.cancel else run
    print(json.dumps(operation(arguments.url), indent=2))

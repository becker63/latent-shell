"""Explicit authenticated one-shot world-generation gate."""

import argparse
import json

from tests.browser_smoke import TRACE, chromium

SEED = "an abandoned university supercomputer that has been running since 1998"


def run(url):
    with chromium() as browser:
        browser.call("Page.addScriptToEvaluateOnNewDocument", {"source": TRACE})
        browser.call("Page.navigate", {"url": url})
        browser.wait("document.readyState === 'complete'")
        browser.wait("document.querySelector('#world')?.open === true")
        browser.evaluate(
            'document.querySelector("#seed").value = '
            + json.dumps(SEED)
            + '; document.querySelector("form").requestSubmit()'
        )
        browser.wait(
            "worldRequests.length === 1 && worldRequests[0].done",
            timeout=120,
        )
        browser.ready()

        response = browser.evaluate("worldRequests[0].response")
        entries = response["image"]["entries"]
        assert entries
        directory = next(
            entry
            for entry in entries
            if entry["kind"] == "directory" and entry["path"] != "/"
        )
        directory_path = directory["path"]
        browser.enter("cd " + json.dumps(directory_path))
        browser.ready(directory_path)
        browser.enter("ls -lah")
        browser.ready(directory_path)

        file_entry = next(
            (
                entry
                for entry in entries
                if entry["kind"] == "file"
                and entry["path"].rsplit("/", 1)[0] == directory_path
            ),
            next(entry for entry in entries if entry["kind"] == "file"),
        )
        browser.enter("cat " + json.dumps(file_entry["path"]))
        browser.ready(directory_path)
        browser.enter("head -n 3 " + json.dumps(file_entry["path"]))
        browser.ready(directory_path)
        browser.enter("stat " + json.dumps(file_entry["path"]))
        browser.ready(directory_path)
        browser.enter("wc " + json.dumps(file_entry["path"]))
        browser.ready(directory_path)
        browser.enter("evidence")
        browser.ready(directory_path)
        browser.enter("rm " + json.dumps(file_entry["path"]))
        browser.ready(directory_path)
        browser.enter("ls")
        browser.ready(directory_path)

        assert browser.evaluate("worldRequests.length") == 1
        assert "world generation failed" not in browser.text()
        print(
            json.dumps(
                {
                    "status": "PASS",
                    "seed": SEED,
                    "entry_count": len(entries),
                    "serialized_bytes": len(json.dumps(response["image"]).encode()),
                    "world_generation_requests": 1,
                    "command_time_model_requests": 0,
                    "directory": directory_path,
                    "sampled_file": file_entry["path"],
                },
                indent=2,
            )
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    run(parser.parse_args().url)

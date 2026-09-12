"""Derive model-only capabilities from the pinned runtime's own model catalog."""

import json
import sys
from pathlib import Path


def generate(source: Path, destination: Path) -> None:
    catalog = json.loads(source.read_text())
    for model in catalog["models"]:
        model.update(
            apply_patch_tool_type=None,
            experimental_supported_tools=[],
            shell_type="disabled",
            tool_mode=None,
            supports_search_tool=False,
            include_skills_usage_instructions=False,
            include_apps_usage_instructions=False,
            include_plugin_usage_instructions=False,
            node_repl_disabled=True,
        )
    destination.write_text(json.dumps(catalog))


if __name__ == "__main__":
    generate(Path(sys.argv[1]), Path(sys.argv[2]))

#!/usr/bin/env python3
"""
GitOps image update.

Rewrites image.repository and image.tag in the deployed values file. This is the
ONLY way a new version reaches the cluster: CI commits the change, Argo CD
observes the drift and syncs it.

Uses a line-oriented rewrite rather than a YAML round-trip so that comments and
formatting in the values file survive — the file is meant to be read and edited
by humans too.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


def rewrite(text: str, repository: str, tag: str) -> str:
    """Replace repository/tag inside the top-level `image:` block only."""
    lines = text.splitlines()
    out: list[str] = []
    in_image_block = False
    seen_repo = False
    seen_tag = False

    for line in lines:
        stripped = line.strip()

        # A non-indented, non-comment key ends the current block.
        if line and not line[0].isspace() and not stripped.startswith("#"):
            in_image_block = stripped.startswith("image:")

        if in_image_block and re.match(r"^\s+repository:\s*", line):
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}repository: {repository}")
            seen_repo = True
            continue

        if in_image_block and re.match(r"^\s+tag:\s*", line):
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f'{indent}tag: "{tag}"')
            seen_tag = True
            continue

        out.append(line)

    if not seen_repo:
        raise SystemExit("error: no image.repository key found in the values file")
    if not seen_tag:
        raise SystemExit("error: no image.tag key found in the values file")

    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--values", required=True, help="path to the values file")
    parser.add_argument("--repository", required=True, help="full image repository")
    parser.add_argument("--tag", required=True, help="immutable image tag (git SHA)")
    args = parser.parse_args()

    if args.tag in ("latest", ""):
        raise SystemExit("error: refusing a mutable image tag; use the Git SHA")

    path = pathlib.Path(args.values)
    if not path.is_file():
        raise SystemExit(f"error: values file not found: {path}")

    updated = rewrite(path.read_text(encoding="utf-8"), args.repository, args.tag)
    path.write_text(updated, encoding="utf-8")

    print(f"{path}: image -> {args.repository}:{args.tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

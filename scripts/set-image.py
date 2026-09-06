#!/usr/bin/env python3
"""
GitOps values update.

Rewrites keys in the deployed values file. This is the ONLY way a new desired
state reaches the cluster: CI commits the change, Argo CD observes the drift
and syncs it.

SINGLE WRITER RULE
------------------
Every environment-specific value the ShopFast chart needs must live HERE, in
git, in the file the Application reads. Nothing may be injected into the
Application object at apply time: the root App-of-Apps reconciles the child
Applications from git, so an apply-time patch is a SECOND writer for the same
field. Root reverts it, the patcher re-adds it, and the two fight forever —
the Application never leaves OutOfSync and the workload is never created.

That is why the ACM certificate ARN is written into the values file by CI
rather than passed as a Helm parameter on the Application.

Uses a line-oriented rewrite rather than a YAML round-trip so that comments and
formatting in the values file survive — the file is meant to be read and edited
by humans too.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


def set_key(text: str, block: str, key: str, value: str, *, quote: bool) -> str:
    """Replace `key` inside the given top-level `block:` only.

    Scoping to a block matters: `tag:` and `host:` appear under more than one
    top-level key in a real values file, and a global regex would corrupt the
    wrong one.
    """
    lines = text.splitlines()
    out: list[str] = []
    in_block = False
    seen = False

    rendered = f'"{value}"' if quote else value

    for line in lines:
        stripped = line.strip()

        # A non-indented, non-comment key ends the current block.
        if line and not line[0].isspace() and not stripped.startswith("#"):
            in_block = stripped.startswith(f"{block}:")

        if in_block and not seen and re.match(rf"^\s+{re.escape(key)}:\s*", line):
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}{key}: {rendered}")
            seen = True
            continue

        out.append(line)

    if not seen:
        raise SystemExit(
            f"error: no {block}.{key} key found in the values file; "
            "refusing to guess where it belongs"
        )

    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--values", required=True, help="path to the values file")
    parser.add_argument("--repository", help="full image repository")
    parser.add_argument("--tag", help="immutable image tag (git SHA)")
    parser.add_argument(
        "--certificate-arn",
        help="ACM certificate ARN for the ingress (resolved from terraform state)",
    )
    args = parser.parse_args()

    path = pathlib.Path(args.values)
    if not path.is_file():
        raise SystemExit(f"error: values file not found: {path}")

    text = path.read_text(encoding="utf-8")
    changes: list[str] = []

    if args.repository or args.tag:
        if not (args.repository and args.tag):
            raise SystemExit("error: --repository and --tag must be given together")
        if args.tag in ("latest", ""):
            raise SystemExit("error: refusing a mutable image tag; use the Git SHA")
        text = set_key(text, "image", "repository", args.repository, quote=False)
        text = set_key(text, "image", "tag", args.tag, quote=True)
        changes.append(f"image -> {args.repository}:{args.tag}")

    if args.certificate_arn:
        if not args.certificate_arn.startswith("arn:aws:acm:"):
            raise SystemExit(
                "error: --certificate-arn does not look like an ACM ARN: "
                f"{args.certificate_arn}"
            )
        text = set_key(
            text, "ingress", "certificateArn", args.certificate_arn, quote=True
        )
        changes.append("ingress.certificateArn updated")

    if not changes:
        raise SystemExit("error: nothing to do; pass --repository/--tag and/or --certificate-arn")

    path.write_text(text, encoding="utf-8")
    for change in changes:
        print(f"{path}: {change}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

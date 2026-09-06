#!/usr/bin/env python3
"""
Commit the ACM certificate ARN into the monitoring Application's Grafana ingress.

WHY A SEPARATE SCRIPT FROM set-image.py
---------------------------------------
set-image.py rewrites keys inside a plain Helm values file, scoping each key to
a TOP-LEVEL block. Grafana's ingress annotations are not top-level: they live
inside `spec.source.helm.values`, an embedded YAML document nested roughly eight
levels deep inside an Argo CD Application manifest. Teaching the block-scoped
rewriter to reach in there would make it guess, and a wrong guess corrupts the
manifest that defines the whole monitoring stack.

This script instead targets exactly one thing: the single line carrying the
`alb.ingress.kubernetes.io/certificate-arn` annotation. It refuses to run if it
does not find exactly one such line, so a refactor of the manifest fails the
build loudly instead of silently leaving a stale certificate behind.

SINGLE WRITER RULE
------------------
The root App-of-Apps reconciles gitops/apps/children/*.yaml FROM GIT. Any field
injected into this Application at apply time is a second writer: root reverts
it, the patcher re-adds it, and the Application never leaves OutOfSync. So the
ARN is committed to git here, exactly like the ShopFast image tag.

WHY THE ARN CHANGES AT ALL
--------------------------
ACM cannot add a SAN to an issued certificate. Adding the Grafana hostname
forces a replacement certificate with a NEW ARN, so every consumer must be
re-pointed. Reading it from terraform state (rather than threading it between
jobs) is the self-sufficient job rule: the value is derived from the same
source of truth on every run.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ANNOTATION = "alb.ingress.kubernetes.io/certificate-arn"

# Matches the annotation line and captures its indentation so the rewrite
# preserves the surrounding YAML structure byte-for-byte.
LINE = re.compile(
    rf"^(?P<indent>\s*){re.escape(ANNOTATION)}:\s*(?P<value>.*?)\s*$"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        required=True,
        help="path to the Argo CD Application manifest carrying the Grafana ingress",
    )
    parser.add_argument(
        "--certificate-arn",
        required=True,
        help="ACM certificate ARN resolved from terraform state",
    )
    args = parser.parse_args()

    arn = args.certificate_arn.strip()
    if not arn.startswith("arn:aws:acm:"):
        raise SystemExit(f"error: does not look like an ACM ARN: {arn}")

    path = pathlib.Path(args.manifest)
    if not path.is_file():
        raise SystemExit(f"error: manifest not found: {path}")

    lines = path.read_text(encoding="utf-8").splitlines()

    matches = [i for i, line in enumerate(lines) if LINE.match(line)]
    if len(matches) != 1:
        raise SystemExit(
            f"error: expected exactly one '{ANNOTATION}' line in {path}, "
            f"found {len(matches)}. Refusing to guess which one to rewrite — "
            "the certificate ARN would silently go stale."
        )

    index = matches[0]
    match = LINE.match(lines[index])
    assert match is not None

    current = match.group("value").strip().strip('"').strip("'")
    if current == arn:
        print(f"{path}: certificate ARN already current — no change.")
        return 0

    lines[index] = f'{match.group("indent")}{ANNOTATION}: "{arn}"'
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{path}: certificate ARN updated to {arn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

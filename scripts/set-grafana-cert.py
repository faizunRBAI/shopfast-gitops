#!/usr/bin/env python3
"""
Commit the ACM certificate ARN into the Grafana ingress annotations.

TARGET FILE (moved 2026-09-07)
------------------------------
This used to rewrite gitops/apps/children/monitoring.yaml, because the chart
values lived inline inside that Argo CD Application manifest. The monitoring
Application is now MULTI-SOURCE and its values live in a plain file:

    gitops/monitoring/values.yaml

The rewrite logic is unchanged — it targets a single annotation line and does
not care how deeply it is nested — but the target is now an ordinary values
file rather than an Application manifest. That is the point of the move: see
"WHY THIS MATTERS" below.

WHY A SEPARATE SCRIPT FROM set-image.py
---------------------------------------
set-image.py rewrites keys inside a plain Helm values file, scoping each key to
a TOP-LEVEL block. Grafana's ingress annotations are not top-level: they sit
several levels down under `grafana.ingress.annotations`. Teaching the
block-scoped rewriter to reach in there would make it guess, and a wrong guess
corrupts the configuration of the whole monitoring stack.

This script instead targets exactly one thing: the single line carrying the
`alb.ingress.kubernetes.io/certificate-arn` annotation. It refuses to run if it
does not find exactly one such line, so a refactor of the file fails the build
loudly instead of silently leaving a stale certificate behind.

WHY THIS MATTERS — THE ATTEMPT 24 DEADLOCK
------------------------------------------
When this ARN lived inside the Application manifest, three things were coupled
that should not have been: the definition of the monitoring app, a value CI
rewrites, and a guard that compares that value against the ShopFast copy.

On 2026-09-07 the ARN in the Application went stale (an ACM replacement during
a provision-only run rewrote the ShopFast copy but not this one). The guard,
correctly, failed the `security` stage. But `security` runs BEFORE `build_push`
— and build_push is the only stage that runs this script. So the single thing
that would have healed the value could never run. The build was deadlocked by
its own guard.

Pointing this script at a plain values file removes the coupling: the file is
not reconciled by the root App-of-Apps, and rewriting it is an ordinary
GitOps commit rather than an edit to a live Application definition.

SINGLE WRITER RULE
------------------
The values file is reconciled from git via the Application's `$values` source.
Any field injected into the live release at apply time is a second writer:
Argo reverts it, the patcher re-adds it, and the app never leaves OutOfSync. So
the ARN is committed to git here, exactly like the ShopFast image tag.

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
        help=(
            "path to the file carrying the Grafana ingress certificate-arn "
            "annotation (gitops/monitoring/values.yaml)"
        ),
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

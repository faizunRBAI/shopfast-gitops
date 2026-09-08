#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Coverage-gate self-test — runs in the `security` stage, offline.
#
# WHY THIS EXISTS
#   A coverage gate has one silent failure mode that looks exactly like a
#   passing build: it is present in the pom, it produces a report, and it
#   enforces NOTHING. Two independent ways to reach that state:
#
#     1. jacoco:check binds to the `verify` phase. If the pipeline runs
#        `mvn test`, Maven stops at `test` — prepare-agent runs, jacoco.exec is
#        written, a report may even be produced, but `check` never executes.
#        Nobody notices, because the stage is green.
#
#     2. haltOnFailure=false turns the gate into a warning. The threshold is
#        still printed in the log, the build still passes below it.
#
#   A future edit that "simplifies" the test stage back to `mvn test`, or flips
#   haltOnFailure, would disarm the gate without changing a single visible
#   number. This asserts both properties so that edit fails the build instead.
#
#   Same reasoning as verify-rollback.sh: a control is only trustworthy if the
#   thing that makes it a control is itself tested.
#
# HOW IT INSPECTS (this part matters — an earlier draft of this script was
# itself buggy):
#   It does NOT try to strip XML comments with sed. A `/<!--/,/-->/d` range
#   delete is unreliable across a file with many multi-line comments — the range
#   can span from one comment's opener to a LATER comment's closer and silently
#   swallow real configuration in between, which would make this guard fail a
#   perfectly correct pom. Instead every check matches a STRUCTURAL XML/YAML
#   token that cannot appear in prose: a full element like
#   <haltOnFailure>true</haltOnFailure>, or an anchored `run:` command line.
#   Prose mentions the words; only real configuration carries the tags.
#
# No network, no cluster, no Maven run — pure static assertions over the repo.
# ---------------------------------------------------------------------------
set -uo pipefail

FAILURES=0
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)) || true; }
pass() { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POM="${REPO_ROOT}/application/pom.xml"
SPEC="${REPO_ROOT}/.udap/pipeline.yaml"

echo "=== Coverage gate verification ==="

[ -f "${POM}" ]  || { fail "missing ${POM}";  exit 1; }
[ -f "${SPEC}" ] || { fail "missing ${SPEC}"; exit 1; }

# --- 1. the plugin is actually declared as a build plugin -------------------
# <artifactId>jacoco-maven-plugin</artifactId> is a structural token; the words
# "jacoco" and "coverage" appear all over the comments and are not matched.
if grep -q '<artifactId>jacoco-maven-plugin</artifactId>' "${POM}"; then
  pass "jacoco-maven-plugin is declared in application/pom.xml"
else
  fail "jacoco-maven-plugin is not declared — there is no coverage gate at all"
fi

# --- 2. the check goal is bound ---------------------------------------------
if grep -q '<goal>check</goal>' "${POM}"; then
  pass "the jacoco:check goal is bound"
else
  fail "jacoco:check is not bound — coverage would be REPORTED but never enforced"
fi

# --- 3. the gate actually halts the build -----------------------------------
# The whole point of the gate. haltOnFailure=false is a warning, not a gate.
# Matched as a complete element so the prose above cannot satisfy it.
if grep -q '<haltOnFailure>true</haltOnFailure>' "${POM}"; then
  pass "haltOnFailure is true — a build below threshold FAILS"
elif grep -q '<haltOnFailure>' "${POM}"; then
  fail "haltOnFailure is present but not 'true' — the gate reports instead of blocking"
else
  fail "haltOnFailure is not set — jacoco:check defaults are not relied upon here"
fi

# --- 4. a LINE threshold above zero is enforced -----------------------------
# Read from the property ELEMENT, which only exists as real configuration.
#
# BRANCH is deliberately allowed to be 0.00 while the covered scope has no
# branches: JaCoCo reports a 0/0 counter as 0.00, NOT 1.00, so a positive branch
# minimum would fail a build that has no branches to cover at all. Only LINE is
# asserted positive here. See application/pom.xml for that rationale.
line_ratio="$(grep -oE '<jacoco\.line\.ratio>[0-9]+\.?[0-9]*</jacoco\.line\.ratio>' "${POM}" \
  | head -n1 | grep -oE '[0-9]+\.?[0-9]*')"
if [ -n "${line_ratio}" ] && awk "BEGIN{exit !(${line_ratio} > 0)}"; then
  pass "LINE coverage minimum is enforced at ${line_ratio}"
else
  fail "no positive LINE coverage minimum found (got '${line_ratio:-none}') — the gate is a no-op"
fi

# --- 5. the LINE limit is actually wired to the property --------------------
# A threshold property that no <limit> references is decoration.
if grep -q '<minimum>${jacoco.line.ratio}</minimum>' "${POM}"; then
  pass "the LINE limit consumes jacoco.line.ratio"
else
  fail "no <limit> consumes jacoco.line.ratio — the threshold is not wired to a rule"
fi

# --- 6. the pipeline runs a phase that REACHES check ------------------------
# THE BINDING TRAP: `mvn test` never runs jacoco:check.
#
# Anchored to a real command line (leading whitespace then `mvn`), so the long
# explanatory comments in the spec — which necessarily contain the words
# "mvn test" and "verify" — cannot satisfy this. A YAML comment line always has
# `#` before any `mvn`, so requiring `mvn` at the start of the trimmed line
# excludes prose without needing to strip comments.
if grep -qE '^[[:space:]]*mvn( |$).*(verify|install)([[:space:]]|$)' "${SPEC}"; then
  pass "the pipeline runs a lifecycle phase that reaches jacoco:check"
else
  fail "no 'mvn verify' (or later) command in the pipeline — jacoco:check binds to verify, so 'mvn test' would skip the gate entirely while staying green"
fi

# --- 7. the exclusion list must not hide application logic ------------------
# Excluding the uncoverable bootstrap class is legitimate: main() is never
# invoked by @SpringBootTest. Excluding the package where the tested logic lives
# would hollow the gate out while every number still looked healthy.
if grep -oE '<exclude>[^<]*</exclude>' "${POM}" \
     | grep -qiE '(api|controller|service|/\*\*/\*\.class$)'; then
  fail "a coverage exclusion covers application logic (api/controller/service or a blanket **/*) — that empties the gate while keeping it green"
else
  pass "coverage exclusions do not hide application logic"
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  printf '\033[1;31mCoverage gate verification FAILED (%s problem(s)).\033[0m\n' "${FAILURES}"
  exit 1
fi

printf '\033[1;32mCoverage gate verified: present, bound, halting, wired, and reached by the pipeline.\033[0m\n'

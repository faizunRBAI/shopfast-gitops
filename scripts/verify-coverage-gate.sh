#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Coverage-gate self-test — runs in the `security` stage, offline.
#
# WHY THIS EXISTS
#   A coverage gate has one silent failure mode that looks exactly like a
#   passing build: it is present in the pom, it produces a report, and it
#   enforces NOTHING. There are four independent ways to reach that state on
#   this project, and this script asserts against all of them:
#
#     1. BINDING. jacoco:check binds to the `verify` phase. A pipeline that runs
#        `mvn test` stops at `test` — prepare-agent runs, jacoco.exec is
#        written, a report may even be produced, but `check` never executes.
#        Nobody notices, because the stage is green.
#
#     2. haltOnFailure=false turns the gate into a warning. The threshold is
#        still printed in the log, the build still passes below it.
#
#     3. EMPTY EXECUTION DATA (new in the split layout, 2026-09-08). The gate
#        now runs in its OWN job, on its own runner, with its own filesystem.
#        jacoco:check with no target/jacoco.exec does not error — it grades an
#        empty data set. That direction fails the build rather than passing it,
#        so it is not silent; but the fix people reach for under time pressure
#        is to lower the threshold, which IS silent from then on. So the
#        artifact hand-off is asserted structurally here.
#
#     4. UNREACHABLE CONFIGURATION (added 2026-09-08 after a real CI failure).
#        The settings can all be PRESENT in the pom and still not be SEEN by the
#        command the pipeline runs. A goal invoked from the command line does
#        not inherit an <execution>'s <configuration>: `mvn jacoco:check` runs
#        as a synthetic `(default-cli)` execution that reads ONLY the
#        plugin-level <configuration>. With <rules> nested inside the named
#        <execution>, checks 3 and 5 below both PASSED while the real build died
#        on "The parameters 'rules' ... are missing or invalid".
#        Presence is not reachability. Check 10 asserts reachability.
#
#   A future edit that "simplifies" the coverage stage back into `mvn test`,
#   flips haltOnFailure, drops the artifact hand-off, or re-nests the rules
#   inside the execution would disarm or break the gate. This asserts those
#   properties so that edit fails the build instead.
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
#   <haltOnFailure>true</haltOnFailure>, or an anchored `mvn` command line.
#   Prose mentions the words; only real configuration carries the tags.
#
#   Where an assertion is about ONE artifact's settings, it is scoped to that
#   artifact's own block rather than grepped file-wide — a file-wide grep for
#   `if-no-files-found: error` would keep passing after the exec-data upload was
#   downgraded to `warn`, because some OTHER upload still used `error`. A guard
#   that passes on the wrong evidence is worse than no guard.
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
# NOTE: this asserts PRESENCE only. Check 10 asserts it is REACHABLE from the
# invocation the pipeline uses — the two are genuinely different properties.
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

# --- 6. the pipeline actually INVOKES the gate ------------------------------
# THE BINDING TRAP, restated for the split layout.
#
# Before 2026-09-08 the gate rode along inside `mvn verify` in the test stage,
# and this check asserted that `mvn verify` existed. The gate now lives in its
# own `coverage` stage which invokes the GOAL directly (`mvn jacoco:check`) so
# that it grades the existing execution data instead of re-running the whole
# suite on a fresh runner. So `mvn verify` is legitimately gone, and asserting
# it would fail a correct pipeline — the exact failure mode where a guard
# refuses correct artifacts because it outlived its assumption.
#
# What must remain true either way: SOME real command line runs jacoco:check,
# or reaches a lifecycle phase (verify/install) that binds it. Accept both, so
# a future consolidation back into `mvn verify` is not spuriously rejected.
#
# Anchored to a real command line (leading whitespace then `mvn`), so the long
# explanatory comments in the spec — which necessarily contain the words
# "mvn test", "verify" and "jacoco:check" — cannot satisfy this. A YAML comment
# line always has `#` before any `mvn`, so requiring `mvn` at the start of the
# trimmed line excludes prose without needing to strip comments.
if grep -qE '^[[:space:]]*mvn( |$).*jacoco:check([[:space:]]|$)' "${SPEC}"; then
  pass "the pipeline invokes jacoco:check directly"
  GATE_INVOCATION="goal"
elif grep -qE '^[[:space:]]*mvn( |$).*(verify|install)([[:space:]]|$)' "${SPEC}"; then
  pass "the pipeline runs a lifecycle phase that reaches jacoco:check"
  GATE_INVOCATION="phase"
else
  fail "no command runs jacoco:check and none reaches the verify phase — jacoco:check binds to verify, so 'mvn test' alone would skip the gate entirely while staying green"
  GATE_INVOCATION="none"
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

# --- 8. the gate must receive the execution data ----------------------------
# ONLY MEANINGFUL WHEN THE GATE RUNS AS A SEPARATE JOB (GATE_INVOCATION=goal).
#
# Stages are separate GitHub jobs on separate runners with separate
# filesystems. `mvn jacoco:check` in its own job sees an EMPTY target/ unless
# jacoco.exec AND the compiled classes are handed over as an artifact:
#
#   jacoco.exec  — which lines were executed
#   classes/     — the bytecode those probe ids refer to; without it the report
#                  and the check resolve nothing
#
# Deleting either side of that hand-off makes the gate measure 0% and fail every
# build. The tempting "fix" at that point is to lower the threshold, which
# disarms the gate permanently and silently. So assert the hand-off exists.
#
# The paths are matched WITH their `application/` prefix. That is deliberate:
# the surrounding prose in the spec writes them as `target/jacoco.exec` and
# `classes/`, so only the real `path:` entries carry the full prefix and the
# comments cannot satisfy this check.
#
# If the gate is ever consolidated back into a single `mvn verify` job, the
# hand-off is unnecessary by construction and this check correctly skips.
if [ "${GATE_INVOCATION}" = "goal" ]; then
  if grep -q 'name: coverage-exec-data' "${SPEC}" \
     && grep -q 'application/target/jacoco.exec' "${SPEC}" \
     && grep -q 'application/target/classes' "${SPEC}"; then
    pass "execution data (jacoco.exec + classes) is handed to the coverage stage"
  else
    fail "the coverage stage runs jacoco:check in a separate job but no coverage-exec-data artifact carries jacoco.exec and target/classes to it — the gate would grade an EMPTY data set as 0%"
  fi

  # The exec-data upload must FAIL, not warn, when there is nothing to upload.
  # With `warn`, a run that produced no coverage data uploads an empty artifact,
  # the coverage job downloads nothing, and jacoco:check reports 0% — a failure
  # two jobs downstream of the real one, blamed on the wrong thing.
  #
  # SCOPED to this artifact's own block: a file-wide grep would still pass after
  # someone downgraded THIS upload to `warn`, because the trivy and report
  # uploads legitimately use `warn`. Read the 12 lines following the artifact's
  # name and assert within them.
  exec_block="$(grep -A 12 'name: coverage-exec-data' "${SPEC}" | grep 'if-no-files-found:' | head -n1)"
  case "${exec_block}" in
    *error*)
      pass "a missing execution-data upload fails fast rather than warning" ;;
    "")
      fail "the coverage-exec-data upload declares no if-no-files-found — missing execution data would surface as a bogus 0% gate failure two jobs later" ;;
    *)
      fail "the coverage-exec-data upload uses '${exec_block# }' instead of if-no-files-found: error — missing execution data would surface as a bogus 0% gate failure two jobs later" ;;
  esac
else
  pass "gate runs in-phase; no cross-job artifact hand-off required (skipped)"
fi

# --- 9. the coverage report must survive a FAILING gate ---------------------
# The run where you most need to know WHICH lines are uncovered is the run where
# the gate just failed. The pipeline spec schema has no `if:` key, so an upload
# step placed after the gate in the coverage stage cannot run with
# if: always() — it would be skipped on exactly that run.
#
# So the report is generated and uploaded in the always-green test stage, which
# is why `mvn test jacoco:report` appends the report goal there. Assert both
# halves: something generates the report, and the artifact is declared.
if grep -qE '^[[:space:]]*mvn( |$).*jacoco:report([[:space:]]|$)' "${SPEC}" \
   || [ "${GATE_INVOCATION}" = "phase" ]; then
  pass "a coverage report is generated independently of the gate"
else
  fail "nothing runs jacoco:report — a gate failure would report a ratio with no way to see which lines are uncovered"
fi

if grep -q 'name: jacoco-coverage-report' "${SPEC}"; then
  pass "the coverage report is uploaded as a run artifact"
else
  fail "no jacoco-coverage-report artifact is uploaded — a gate failure would not be diagnosable from the run"
fi

# --- 10. the rules must be REACHABLE from the pipeline's invocation ---------
# PRESENCE IS NOT REACHABILITY. This is the check that checks 3 and 5 cannot
# make, and its absence cost a real CI failure on 2026-09-08:
#
#   [INFO] --- jacoco:0.8.12:check (default-cli) @ shopfast ---
#                                   ^^^^^^^^^^^ not (jacoco-check)
#   [ERROR] The parameters 'rules' for goal
#           org.jacoco:jacoco-maven-plugin:0.8.12:check are missing or invalid
#
# Maven applies an <execution>'s <configuration> ONLY when the goal runs via
# that execution's phase binding. `mvn jacoco:check` from the command line
# creates a synthetic `default-cli` execution which reads ONLY the PLUGIN-level
# <configuration>. So when the pipeline invokes the goal directly, <rules> and
# <haltOnFailure> MUST live at plugin level. Nested in the execution they are
# present, greppable, and invisible to the actual build.
#
# HOW THIS IS DETECTED without an XML parser:
#   Take the jacoco plugin's own text, from its <artifactId> line up to the
#   <executions> opening tag. That window is exactly the plugin-level
#   configuration region — anything after <executions> belongs to an execution.
#   Requiring <rules> and <haltOnFailure> inside that window proves they are in
#   plugin scope, not execution scope.
#
#   Comments cannot satisfy it: the window is matched for the literal element
#   tags <rules> and <haltOnFailure>true</haltOnFailure>, and the long comment
#   in the pom writes them without tags (as "rules"/"haltOnFailure") precisely
#   so that prose can never stand in for configuration.
#
# ONLY ASSERTED for the goal invocation. Under a lifecycle phase (`mvn verify`)
# the execution's own configuration IS applied, so plugin-level placement is not
# required and demanding it would refuse a different correct layout.
if [ "${GATE_INVOCATION}" = "goal" ]; then
  # Line numbers bounding the jacoco plugin's plugin-level region.
  jacoco_start="$(grep -n '<artifactId>jacoco-maven-plugin</artifactId>' "${POM}" | head -n1 | cut -d: -f1)"
  if [ -z "${jacoco_start}" ]; then
    fail "cannot locate the jacoco plugin block to verify configuration scope"
  else
    # First <executions> AFTER the plugin's artifactId ends the plugin-level region.
    exec_rel="$(tail -n +"${jacoco_start}" "${POM}" | grep -n '<executions>' | head -n1 | cut -d: -f1)"
    if [ -z "${exec_rel}" ]; then
      # No executions at all: the whole plugin block is plugin-level.
      plugin_scope="$(tail -n +"${jacoco_start}" "${POM}")"
    else
      plugin_scope="$(tail -n +"${jacoco_start}" "${POM}" | head -n "${exec_rel}")"
    fi

    scope_ok=1
    case "${plugin_scope}" in
      *"<rules>"*) : ;;
      *) scope_ok=0 ;;
    esac
    case "${plugin_scope}" in
      *"<haltOnFailure>true</haltOnFailure>"*) : ;;
      *) scope_ok=0 ;;
    esac

    if [ "${scope_ok}" -eq 1 ]; then
      pass "<rules> and haltOnFailure are at PLUGIN level — reachable by 'mvn jacoco:check'"
    else
      fail "the pipeline runs 'mvn jacoco:check' (a default-cli execution) but <rules>/<haltOnFailure> are not in the plugin-level <configuration> — a CLI-invoked goal does NOT inherit an <execution>'s configuration, so the build dies with \"The parameters 'rules' ... are missing or invalid\""
    fi
  fi
else
  pass "gate runs in-phase; execution-level configuration is applied (scope check skipped)"
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  printf '\033[1;31mCoverage gate verification FAILED (%s problem(s)).\033[0m\n' "${FAILURES}"
  exit 1
fi

printf '\033[1;32mCoverage gate verified: present, bound, halting, wired, reachable, fed, reported, and invoked by the pipeline.\033[0m\n'

# Test coverage gate

The **`coverage`** stage enforces a JaCoCo line-coverage minimum. A build below
the threshold **fails**; it is a gate, not a report.

This document explains the things that are easy to get wrong about it, and why
the numbers are what they are.

---

## 1. Where it runs

| | |
|---|---|
| Plugin | `jacoco-maven-plugin` 0.8.12, `application/pom.xml` |
| Tests run in | the `test` stage — `mvn -B -ntp test jacoco:report` |
| Gate enforced in | the **`coverage`** stage — `mvn -B -ntp jacoco:check` |
| Blocking? | **Yes** — `haltOnFailure` is `true` |
| Report | `jacoco-coverage-report` artifact, uploaded by the `test` stage |
| Hand-off | `coverage-exec-data` artifact (`jacoco.exec` + `target/classes`) |
| Self-test | `scripts/verify-coverage-gate.sh`, `security` stage |

Pipeline order:

```
lint -> test -> coverage -> security -> provision -> build_push -> configure -> verify
```

Coverage is its **own job**, so when it goes red the failure is named for what
actually broke — not buried inside a test stage that also compiles, packages
and runs the suite.

The container image build is **unaffected**: `application/Dockerfile` runs
`mvn -DskipTests package`, so the gate cannot break `build_push`.

---

## 2. Two ways a coverage gate silently enforces nothing

### 2a. The binding trap — `mvn test` never runs `check`

`jacoco:check` binds to the **`verify`** lifecycle phase. `mvn test` stops at
`test`. With `mvn test` alone:

- `prepare-agent` runs,
- `jacoco.exec` is written,
- a report may even be produced,
- and **`check` never executes**.

The gate is fully configured in `pom.xml`, enforces nothing, and the stage is
green. Nothing in the log says the threshold was skipped.

The `coverage` stage therefore invokes the **goal directly** — `mvn jacoco:check`
— which does not depend on reaching any lifecycle phase.

### 2b. The empty-data trap — introduced by splitting the job

Every stage is a **separate GitHub job on a separate runner with its own
filesystem**. Nothing survives a job boundary.

So the naive split is wrong in two different ways:

| Attempt | What actually happens |
|---|---|
| `coverage` runs `mvn verify` | Re-runs the **entire test suite** on a fresh runner. Duplicated work on the slowest stage. |
| `coverage` runs `mvn verify -DskipTests` | The agent never attaches, `jacoco.exec` is empty, JaCoCo measures **0%** — the gate fails correct code. |

The correct split: the `test` stage **produces** the execution data, the
`coverage` stage **grades** it.

```
test stage                                coverage stage
  mvn test jacoco:report                    download coverage-exec-data
  upload jacoco.exec + target/classes  -->  mvn jacoco:check
```

Both paths in the hand-off are load-bearing:

- **`jacoco.exec`** — which lines were executed.
- **`target/classes`** — the bytecode those probe ids refer to. Without it
  JaCoCo resolves nothing and the report comes out empty.

The upload uses `if-no-files-found: error`. With `warn`, a run that produced no
coverage data would upload an empty artifact and the failure would surface **two
jobs later** as a bogus 0%, blamed on the wrong thing.

---

## 3. Why the report is generated in the `test` stage

The run where you most need to see *which* lines are uncovered is the run where
the gate just failed.

The pipeline spec schema has **no `if:` key**, so an upload step placed after
the gate in the `coverage` stage cannot use `if: always()` — it would be skipped
on exactly the run that needed it.

So `jacoco:report` is appended to the `test` stage's command
(`mvn test jacoco:report`) and the artifact is uploaded there, in a stage that
does not fail on coverage. The report always exists, whatever the gate decides.

---

## 4. The thresholds, and why they are not round numbers

```xml
<jacoco.line.ratio>0.90</jacoco.line.ratio>
<jacoco.branch.ratio>0.00</jacoco.branch.ratio>
```

### LINE = 0.90

The measured scope is one class, `HelloController` (see the exclusion below).
Its constructor and `hello()` method are both fully exercised, so the honest
ratio today is **1.00**.

The bar is set at 0.90, not 1.00, deliberately. A gate pinned to exactly the
current value fails on the very next line of code that is not immediately
tested — which trains people to lower the gate rather than write the test. 0.90
leaves room for one honest gap while still refusing a real regression.

### BRANCH = 0.00 — this is not a disabled check

`hello()` contains no conditional, so the measured scope has **zero branches**.

JaCoCo reports a `0/0` counter as a **0.00 ratio, not 1.00**. A branch minimum
above zero would therefore fail a build that has no branches to cover in the
first place.

The limit is kept **declared** rather than deleted so that it starts enforcing
the moment real conditional logic lands. When that happens, raise
`jacoco.branch.ratio` — by then the 0/0 problem no longer exists.

---

## 5. What is excluded, and why that is honest

```xml
<exclude>xyz/royalbengal/shopfast/ShopFastApplication.class</exclude>
```

`main()` is **never invoked by `@SpringBootTest`**. Spring Test builds the
`ApplicationContext` directly; it does not go through `main()`. The only way to
"cover" that method is a test that calls `main()` purely to colour a line green,
which asserts nothing about behaviour.

Excluding an uncoverable bootstrap class is the standard treatment. Writing a
fake test for it is coverage theatre — it raises the number without raising
confidence, which is the failure mode a coverage gate is supposed to prevent.

**Nothing else is excluded**, and check 7 of the self-test fails the build if an
exclusion ever starts covering `api` / `controller` / `service` classes or uses
a blanket `**/*`. That is the realistic way this gate would be hollowed out:
not by lowering the number, but by shrinking what the number measures.

---

## 6. What the self-test asserts

`scripts/verify-coverage-gate.sh` runs offline in the `security` stage:

| # | Assertion | Failure it prevents |
|---|---|---|
| 1 | `jacoco-maven-plugin` is declared | gate removed entirely |
| 2 | `<goal>check</goal>` is bound | coverage reported, never enforced |
| 3 | `haltOnFailure` is `true` | gate downgraded to a warning |
| 4 | LINE minimum > 0 | threshold zeroed out |
| 5 | a `<limit>` consumes `jacoco.line.ratio` | property present but unwired |
| 6 | something runs `jacoco:check` **or** reaches `verify` | the binding trap in §2a |
| 7 | exclusions do not cover app logic | gate hollowed by scope |
| 8 | the exec-data hand-off exists, with `if-no-files-found: error` | the empty-data trap in §2b |
| 9 | a report is generated and uploaded | a gate failure with nothing to diagnose from |

Checks 8 and 9 only apply when the gate runs as its own job. If it is ever
consolidated back into a single `mvn verify`, check 6 accepts that form and
check 8 correctly skips — a guard must not refuse a *different correct* layout.

It matches **structural tokens** (`<haltOnFailure>true</haltOnFailure>`, an
anchored `mvn` command line), never prose. Both files document this gate at
length, and a guard that matched its own explanation would pass on
documentation alone. The exec-data paths are matched **with** their
`application/` prefix for the same reason: the surrounding comments write them
as `target/jacoco.exec`, so only the real `path:` entries can satisfy the check.

It deliberately does **not** try to strip XML comments with `sed`. A
`/<!--/,/-->/d` range delete is unreliable across a file with many multi-line
comments — the range can run from one comment's opener to a later comment's
closer and silently swallow real configuration, which would make the guard fail
a perfectly correct `pom.xml`.

Check 8's `if-no-files-found` assertion is **scoped to its own artifact block**
rather than grepped file-wide. A file-wide grep would keep passing after someone
downgraded the exec-data upload to `warn`, because the Trivy and report uploads
legitimately use `warn`. A guard that passes on the wrong evidence is worse than
no guard.

---

## 7. Raising the bar later

When real business logic lands (persistence, cart, checkout):

1. Run the pipeline and read the `jacoco-coverage-report` artifact.
2. Raise `jacoco.line.ratio` toward the measured value, minus headroom.
3. Set `jacoco.branch.ratio` to a real value — conditionals now exist.
4. Do **not** add exclusions to make the number work. Check 7 will refuse the
   ones that matter, and the ones it allows still cost you real confidence.

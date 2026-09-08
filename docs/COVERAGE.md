# Test coverage gate

The `test` stage enforces a JaCoCo line-coverage minimum. A build below the
threshold **fails**; it is a gate, not a report.

This document explains the two things that are easy to get wrong about it, and
why the numbers are what they are.

---

## 1. Where it runs

| | |
|---|---|
| Plugin | `jacoco-maven-plugin` 0.8.12, `application/pom.xml` |
| Enforced in | the `test` stage of the deploy pipeline |
| Command | `mvn -B -ntp verify` |
| Blocking? | **Yes** — `haltOnFailure` is `true` |
| Report | `jacoco-coverage-report` artifact on every run (HTML + XML) |
| Self-test | `scripts/verify-coverage-gate.sh`, `security` stage |

The container image build is **unaffected**: `application/Dockerfile` runs
`mvn -DskipTests package`, so the gate cannot break `build_push`.

---

## 2. `mvn verify`, NOT `mvn test` — the silent-no-op trap

This is the single most important fact in this document.

`jacoco:check` binds to the **`verify`** lifecycle phase. `mvn test` stops at
`test`. With `mvn test`:

- `prepare-agent` runs,
- `jacoco.exec` is written,
- a report may even be produced,
- and **`check` never executes**.

The gate is fully configured in `pom.xml`, enforces nothing, and the stage is
green. Nothing in the log says the threshold was skipped.

So the pipeline runs `mvn verify`, and `scripts/verify-coverage-gate.sh` asserts
that it still does. If someone later "simplifies" the step back to `mvn test`,
the security stage fails with an explanation rather than quietly disarming the
gate.

`verify` also runs `package`, so the jar is still produced in the same step —
the previously separate package step was redundant and was removed.

---

## 3. The thresholds, and why they are not round numbers

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

## 4. What is excluded, and why that is honest

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

## 5. What the self-test asserts

`scripts/verify-coverage-gate.sh` runs offline in the `security` stage:

| # | Assertion | Failure it prevents |
|---|---|---|
| 1 | `jacoco-maven-plugin` is declared | gate removed entirely |
| 2 | `<goal>check</goal>` is bound | coverage reported, never enforced |
| 3 | `haltOnFailure` is `true` | gate downgraded to a warning |
| 4 | LINE minimum > 0 | threshold zeroed out |
| 5 | a `<limit>` consumes `jacoco.line.ratio` | property present but unwired |
| 6 | the pipeline runs `mvn verify`/`install` | the silent-no-op trap in §2 |
| 7 | exclusions do not cover app logic | gate hollowed by scope |

It matches **structural tokens** (`<haltOnFailure>true</haltOnFailure>`, an
anchored `mvn` command line), never prose. Both files document this gate at
length, and a guard that matched its own explanation would pass on
documentation alone.

It deliberately does **not** try to strip XML comments with `sed`. A
`/<!--/,/-->/d` range delete is unreliable across a file with many multi-line
comments — the range can run from one comment's opener to a later comment's
closer and silently swallow real configuration, which would make the guard fail
a perfectly correct `pom.xml`.

---

## 6. Raising the bar later

When real business logic lands (persistence, cart, checkout):

1. Run the pipeline and read the `jacoco-coverage-report` artifact.
2. Raise `jacoco.line.ratio` toward the measured value, minus headroom.
3. Set `jacoco.branch.ratio` to a real value — conditionals now exist.
4. Do **not** add exclusions to make the number work. Check 7 will refuse the
   ones that matter, and the ones it allows still cost you real confidence.

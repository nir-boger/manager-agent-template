# DM code-review rules (Your Team)

Single source of truth for the additional review checks the `pr-review-assistant`
skill applies on top of generic code-review hygiene. The runner injects the
absolute path to this file into the agent prompt on every review; the agent reads
it verbatim and applies every rule below to the diff under review.

Nir owns this file. Edit it directly to add / refine / drop rules — no other
plumbing needed, the runner picks up the latest content on next invocation.

---

## Scope (READ FIRST)

These rules apply to **DM code only**. DM code = everything under the
`Azure-Kusto-Service` repository **except** the `Kusto.Cloud.Platform.*`
assemblies / namespaces / folders.

If a finding's only basis is a rule below and the changed file lives under
`Kusto.Cloud.Platform`, **do not** raise it — that codebase is intentionally
exempted (it predates these conventions and has its own contracts).

When in doubt about a file's scope, treat the namespace of the type being
modified as the source of truth (a file under `src/Kusto.Cloud.Platform/...`
that declares a `Kusto.DataManagement.*` type is DM code).

---

## Severity assignment for these rules

Each rule below carries a default severity. The agent maps it to the four-tier
output the skill posts to ADO:

- **Blocker** — code that will break, leak, or silently lose data.
- **Concern** — design / scaling / abstraction violations; will hurt us
  operationally even if it "works".
- **Suggestion** — better pattern available; non-blocking.
- **Nit** — only when it materially helps readability.

If a rule's default is overridden by context (e.g. a test-only file, an
internal tool), the agent must say so in the comment body — never silently
downgrade.

---

## R1 — SOLID + CLEAN code (Uncle-Bob school)

**Default severity:** Concern (Blocker if it leads to a correctness bug).

Apply the standard SOLID lenses to every changed type / method:

- **S**ingle responsibility — a class / method does one thing. Flag God
  classes, fat orchestrators, and methods that mix policy with mechanism.
- **O**pen-closed — new behavior should plug in via composition, not by
  editing a switch on a type discriminator.
- **L**iskov — subclasses must honor their base's contract (no
  `NotSupportedException` overrides on virtual members).
- **I**nterface segregation — fat interfaces with many unrelated members get
  a Concern. Prefer narrow role interfaces.
- **D**ependency inversion — depend on abstractions, not concretes (see R3
  for the storage-specific corollary).

CLEAN-code basics worth flagging:

- Methods longer than ~40 lines or with cyclomatic complexity that requires
  scrolling.
- Magic numbers / strings without a named constant.
- Names that lie about intent (`ProcessData()` that also mutates external
  state, `helper` / `manager` / `util` suffixes that hide responsibility).
- Comments that restate the code instead of explaining the *why*.
- Dead code, commented-out blocks, TODOs without a tracking work-item link.

Anti-pattern to call out specifically: a "service" class that owns more than
one of {parsing, scheduling, persistence, network I/O, business logic}.

---

## R2 — COGS & perf must scale on multi-node

**Default severity:** Concern (Blocker if it breaks horizontally).

DM runs on many nodes. Every diff must be read with two questions in mind:

1. **Does this cost more per request than it should?** Flag:
   - Allocations on hot paths (per-row `new`, LINQ in tight loops,
     `string.Format` where interpolation + a pooled buffer would do).
   - Synchronous I/O on the request path.
   - Unbounded in-memory caches / lists keyed by tenant / cluster / blob
     (memory grows with traffic forever).
   - Logging that produces O(n) lines per request (especially
     `TraceInformation` in inner loops).

2. **Does this assume one node?** Flag:
   - Static / process-wide mutable state used as a system-wide registry
     (works on a single box; corrupts on N boxes).
   - In-memory locks / semaphores guarding shared-truth invariants that span
     nodes.
   - "Run once" logic without a distributed-lock / leader-election story.
   - Counters / dashboards aggregated locally instead of emitted as metrics
     for downstream aggregation.

If the diff touches a hot path (anything in the ingest / DM message-processor
pipeline), name the cost in the comment (e.g. "this allocates a `List<string>`
per message; at our DM rate that's ~3M allocations/min/cluster").

---

## R3 — Use PersistentStorageLayer, not vendor storage clients

**Default severity:** Concern (Blocker if it locks us into one cloud).

DM is designed to run on Azure (Azure Blob / Azure Tables) **and** on AWS
(S3 / DynamoDB-equivalent). Every persistence call MUST go through the
**`PersistentStorageLayer` (PSL)** abstraction — never reach for a vendor
SDK type directly from DM business code.

Flag any of the following in a DM file:

- Direct references to `Azure.Storage.Blobs.*` (`BlobClient`,
  `BlobContainerClient`, `BlobServiceClient`, `BlobSasBuilder`, etc.).
- Direct references to `Microsoft.Azure.Cosmos.Table.*` / legacy
  `Microsoft.WindowsAzure.Storage.*` types.
- Direct references to `Amazon.S3.*`, `Amazon.DynamoDBv2.*`, or any other
  AWS SDK namespace.
- Connection-string parsing, SAS-token construction, or container-naming
  logic outside the PSL implementation projects.

Acceptable:

- The PSL implementation projects themselves (they own the vendor calls by
  definition). If unsure whether a project is "an implementation", check
  whether it implements one of the PSL interfaces — if yes, vendor SDK
  references are fine inside it; outside it, they aren't.
- Test fixtures that stub PSL by providing a fake — flag if test code
  reaches for the real Azure / S3 SDK instead of the in-memory PSL fake.

Suggested wording for the comment:

> Reaches into `Azure.Storage.Blobs` directly — DM has to run on AWS too.
> Route this through `IPersistentBlobStore` (or the appropriate PSL
> interface) so the storage backend stays swappable.

When the diff adds a brand-new persistence concept, the right ask is "where
does this go in PSL?" — if the abstraction doesn't exist yet, the PR should
add it (or a follow-up PBI should track adding it) before the concrete
implementation lands.

---

## R4 — Test naming: `MUT_When..._Then|Should|Throws...`

**Default severity:** Suggestion (Concern if the test name actively misleads).

Test method names in DM test projects MUST follow the pattern:

```
<MethodUnderTest>_When<Condition>_<Then|Should|Throws><ExpectedOutcome>
```

Examples (good):

```csharp
ProcessMessage_WhenBlobIsEmpty_ThenSkipsAndLogsWarning()
EstimateSize_WhenFormatIsBinary_ShouldReturnOriginalSize()
Enqueue_WhenQueueIsFull_ThrowsQueueFullException()
```

Anti-patterns to flag:

- `TestProcessMessage()` / `Test1()` / `ShouldWork()` — no MUT, no
  condition, no outcome.
- `Process_Test_Empty()` — uses snake-case-of-concepts instead of the
  When/Then split.
- Names that describe the test setup instead of the behavior under test.

If a test asserts an exception, prefer `Throws` over `Should` / `Then` in
the suffix — it makes greppability for exception coverage trivial.

This rule is for new / modified tests only. Don't ask the author to rename
unrelated pre-existing tests in the same diff.

---

## R5 — FluentAssertions everywhere (including for exceptions)

**Default severity:** Suggestion (Concern when exception assertions are the
issue — those often hide bugs).

DM test projects use **FluentAssertions** as the standard assertion library.
Flag:

- Plain MSTest / xUnit assertions (`Assert.AreEqual`, `Assert.IsTrue`,
  `Assert.IsNotNull`, `Assert.IsInstanceOfType`) when FluentAssertions is
  already referenced in the project.
- `try { ... } catch (FooException) { Assert.Pass(); } catch { Assert.Fail(); }`
  patterns. Replace with:

```csharp
Action act = () => sut.DoThing();
act.Should().Throw<FooException>()
    .WithMessage("*expected fragment*");
```

For async:

```csharp
Func<Task> act = () => sut.DoThingAsync();
await act.Should().ThrowAsync<FooException>();
```

- `Assert.AreEqual(expected, actual)` arg-order traps — `.Should().Be(...)`
  reads correctly every time.

This rule does not require migrating existing assertions wholesale; flag
only new / modified test code in the diff.

---

## R6 — No `Thread.Sleep` / `Task.Delay` (production threads)

**Default severity:** Concern (Blocker on a hot path).

Blocking a thread (or a `Task`) on a timer is almost always a bug in DM
production code: it ties up workers, hides race conditions, and makes the
service flaky under load.

Flag any new occurrence of:

- `Thread.Sleep(...)` in any DM `.cs` file outside `*.Tests.*` /
  `*.IntegrationTests.*` projects.
- `Task.Delay(...)` used as a "wait for something to happen" loop,
  retry-without-backoff, or to paper over a race.
- `await Task.Delay(...)` on a request path where the right answer is
  awaiting an actual signal (event, channel, completion source).

Acceptable:

- `Task.Delay` inside a clearly-scoped retry helper that uses exponential
  backoff with a cancellation token, and only when the alternative
  (async event) genuinely doesn't exist.
- Test code (`*.Tests`) may use either when simulating timing — still
  prefer `await Task.Delay` over `Thread.Sleep` so the test runner thread
  isn't blocked.

Suggested wording:

> `Task.Delay(500)` here is masking a race — what signal are we waiting
> for? Wire that signal through an `AsyncManualResetEvent` or a
> `TaskCompletionSource<T>` so the wait wakes up the instant the
> precondition holds.

---

## R7 — No fire-and-forget async (`_ = SomeAsync(...)`)

**Default severity:** Blocker.

The pattern

```csharp
_ = DoWorkAsync(ct);   // BAD
```

silently drops exceptions, abandons cancellation, and makes shutdown unsafe.
Flag every occurrence in DM code.

Acceptable replacements:

- If the caller can await: just `await DoWorkAsync(ct)`.
- If the work must outlive the caller: schedule it on a known
  `TaskScheduler` (see R8) and store the resulting `Task` in a tracked
  registry that gets awaited at shutdown / observed for faulted state.
- For "background workers", use the appropriate hosted-service /
  `BackgroundService` pattern with explicit lifetime management — never a
  bare `_ = ...` line in a constructor / startup method.

The same applies to the close cousins:

```csharp
DoWorkAsync(ct);                       // BAD — not awaited, not assigned
Task.Run(() => DoWorkAsync(ct));       // BAD — same problem, dressed up
```

Suggested wording:

> Fire-and-forget — if `DoWorkAsync` throws, we lose the exception and the
> task. Either `await` it or hand it to the background-task tracker so
> faults surface and shutdown can drain it.

---

## R8 — Parallelism must be bound to a `ConcurrentExclusiveSchedulerPair`

**Default severity:** Concern (Blocker when it touches shared mutable state).

DM never runs unmanaged parallel work. Every `Task.Run` / `Parallel.*` /
`Task.WhenAll(fanout)` on production paths must be bound to a known
**`ConcurrentExclusiveSchedulerPair`** (or an equivalent scheduler the team
owns) so we can:

- Cap concurrency per workload.
- Serialize exclusive sections without ad-hoc `lock` blocks.
- See the workload in profiling / diagnostics.

Flag:

- `Task.Run(...)` on a production path without a scheduler argument
  threading through a known pair.
- `Parallel.ForEach` / `Parallel.For` / `Parallel.ForEachAsync` without
  `MaxDegreeOfParallelism` AND `TaskScheduler` set from a pair.
- `Task.WhenAll(items.Select(i => ProcessAsync(i)))` with no upstream gate
  on `items.Count` and no scheduler binding.

Suggested wording:

> Unbounded `Task.WhenAll` fan-out — under a burst this can spawn thousands
> of concurrent operations. Route this through the
> `ConcurrentExclusiveSchedulerPair` for this workload (or define one if
> it doesn't exist yet) so we cap concurrency and stay observable.

---

## R9 — Prefer `var` when the RHS makes the type obvious

**Default severity:** Nit (style only — never block on this).

DM C# code prefers `var` whenever the right-hand side already tells the reader
the type, so the eye doesn't bounce between the type and the constructor /
cast / factory.

Flag when an explicit type declaration could be replaced with `var` and the
type stays obvious:

- `new` expressions: `Foo foo = new Foo();` → `var foo = new Foo();`
- Explicit casts: `Foo foo = (Foo)bar;` → `var foo = (Foo)bar;`
- `as` expressions: `Foo foo = bar as Foo;` → `var foo = bar as Foo;`
- Factory / parse / Create methods whose name carries the type:
  `Guid g = Guid.Parse(s);` → `var g = Guid.Parse(s);`,
  `Foo foo = Foo.Create(...);` → `var foo = Foo.Create(...);`.
- Strongly-typed generics where the RHS spells the type:
  `Dictionary<string,int> d = new Dictionary<string,int>();` →
  `var d = new Dictionary<string,int>();` (or target-typed `new()`).

Do NOT raise this when `var` would actually hurt readability:

- Primitive literals where the explicit type is the documentation:
  `decimal price = 0;` (using `var` would make it `int`), `byte b = 1;`,
  `long count = 0L;` — leave as-is.
- Method calls whose names don't encode the return type:
  `IReadOnlyList<Thing> things = GetThings();` — keep explicit.
- LINQ chains where the element type isn't obvious from the source query.
- Numeric calculations where precision matters and is inferred from the RHS
  but not visually obvious.

Pure style nit — only raise it when switching to `var` materially helps the
changed lines. Multiple `var`-able declarations in the same hunk can collapse
into a single comment naming a few examples rather than one comment per line.

Suggested wording:

> `[Nit] R9: this could be `var` — the RHS already names the type.`

---

## Reporting hints (for the agent composing comments)

- Prefix the comment title with the rule ID when the comment is grounded in
  these rules — e.g. `[Concern] R3: Reaches into Azure.Storage.Blobs from DM
  code`. This makes it trivial for Nir to grep which rule fired across
  reviews.
- A single comment can cite multiple rules when they reinforce each other
  (e.g. R6 + R8 on a `Task.Delay(...)` inside a fan-out).
- If a rule fires inside `Kusto.Cloud.Platform`, **do not** post the
  comment (scope exemption — see top of file).
- Rule violations that are pre-existing in unchanged lines are out of scope
  per the skill's general "review the diff, not the codebase" stance —
  unless the diff is the natural place to fix them.


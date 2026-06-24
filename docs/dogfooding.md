# Dogfooding TestLens in a real Phoenix/OTP project

This guide explains how to use TestLens as a **local path dependency** in a
real application before it is published to Hex. It is deliberately written
against a generic `ExampleApp` so any Phoenix/OTP project can follow it.

> **Why this matters.** A test formatter's quality can only be evaluated
> against real failure shapes from a real codebase. Library-only tests
> tend to exercise the happy path. Dogfooding produces the messy
> failures — flaky async, broken contracts, real `FunctionClauseError`s —
> that the formatter has to make readable.

---

## 1. Sibling repo setup

The simplest layout is two repositories side by side. No `git submodule`,
no sub-apps, no umbrella. Just two directories next to each other on disk.

```
~/work/
├── example_app/        # Your Phoenix/OTP project
│   ├── mix.exs
│   ├── config/
│   ├── lib/
│   ├── test/
│   └── .test_lens.exs  # ← added in step 3
└── test_lens/          # ← cloned from this repo
    ├── mix.exs
    ├── lib/
    └── ...
```

```sh
git clone https://github.com/your-org/test_lens.git ~/work/test_lens
cd ~/work/example_app
```

You do not need to `cd` into `test_lens/` or run `mix deps.get` there. The
path dependency will compile it on demand.

---

## 2. Add TestLens as a local path dependency

In your project's `mix.exs`:

```elixir
defp deps do
  [
    # ...your existing deps...

    # TestLens, served from the sibling checkout.
    # - `only: [:dev, :test]` keeps it out of production builds.
    # - `runtime: false` means we don't need it in releases; it only
    #   provides the mix task and formatter modules.
    {:test_lens, path: "../test_lens", only: [:dev, :test], runtime: false}
  ]
end
```

Then in your project's root:

```sh
mix deps.get
mix deps.compile
```

Confirm the task is wired up:

```sh
mix help test.lens
# Should print something like:
#   mix test.lens # Run tests with the TestLens formatter.
```

`mix test.lens` is now a drop-in replacement for `mix test` in this
project.

---

## 3. Create `.test_lens.exs`

The `.test_lens.exs` file lives in your project root. It supplies the
**meaning** of your codebase to TestLens: which paths map to which areas,
which tags are critical, and what `impact` levels mean in your domain.

TestLens supplies the **structure** (the schema, the loader, the
classifier). You supply the **semantics**.

A starting config for a Phoenix app:

```elixir
# .test_lens.exs
[
  project: "ExampleApp",
  areas: [
    "test/example_app/accounts" => [
      label: "Accounts",
      impact: :high,
      user_facing: false
    ],
    "test/example_app_web/controllers" => [
      label: "HTTP controllers",
      impact: :high,
      user_facing: true
    ],
    "test/example_app_web/live" => [
      label: "LiveView/UI",
      impact: :high,
      user_facing: true
    ],
    "test/example_app/workers" => [
      label: "Background jobs",
      impact: :medium,
      user_facing: false
    ],
    "test/example_app/analytics" => [
      label: "Analytics",
      impact: :low,
      user_facing: false
    ]
  ],
  critical_tags: [
    :payment,
    :security,
    :data_integrity,
    :authentication
  ]
]
```

You can leave the file out entirely — TestLens will still work. You will
just see `area: nil, impact: :none, reason: "no matching area or tag"`
on every test. Start with a thin config and grow it.

The file is loaded with `Code.eval_string/1`, so you can use any Elixir
expression that evaluates to a keyword list. Unknown keys are ignored.
Invalid shapes fall back to defaults with a warning on stderr.

---

## 4. Optional: a wrapper script

If you want a one-word entry point (and to make the path dependency
obvious in your CI), drop a shell script in your project:

```sh
# scripts/test-lens
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec mix test.lens "$@"
```

```sh
chmod +x scripts/test-lens
```

Now the team (and CI) runs:

```sh
./scripts/test-lens
./scripts/test-lens -- --failed
./scripts/test-lens --json
```

This also makes it cheap to flip the whole team over to TestLens: replace
`mix test` with `./scripts/test-lens` in your CI config and see the
output change. Compare side by side.

---

## 5. Run modes

### Full suite

```sh
mix test.lens
```

You should see, in order:
- The `== TestLens ==` banner
- A one-line suite status: `N passed, M failed, K skipped, T total in TIMEMS (seed: S)`
- A `── Failures ──` section (only if there are failures), grouped by
  `Critical` / `Other` severity
- A `── Slowest tests ──` section (top 5)
- A `── Next commands ──` section with suggested rerun commands

### Rerun the last failures

```sh
mix test.lens -- --failed
```

This is ExUnit's standard flag. TestLens passes it through unchanged.

### Rerun tests whose source has changed

```sh
mix test.lens -- --stale
```

If your team doesn't use `--stale` already, this is a good moment to start.

### Run by tag

ExUnit's `--only` works as expected:

```sh
# Just the smoke tests
mix test.lens -- --only smoke

# Just the :payment-tagged tests
mix test.lens -- --only payment
```

A test tagged with a `critical_tags` value from your `.test_lens.exs`
will be reported as `critical: true` in the JSON artifact regardless of
which area it lives in.

### JSON artifact for agents and CI

```sh
# Write the JSON artifact to the default location
mix test.lens --json

# Write to a custom path
mix test.lens --json-file tmp/test_lens/report.json -- --failed
```

Default location: `_build/test_lens/report.json`. The artifact has a
stable schema documented in the TestLens README and in the
`TestLens.JSONReport` moduledoc.

---

## 6. How to evaluate whether TestLens output is actually useful

A few questions to ask after each run. Write the answers down — they
become your feedback report in step 7.

**On the suite status line:**
- Can you tell at a glance whether CI passed or failed?
- Does the seed being printed help reproduce a flaky run?
- Is the count breakdown (passed / failed / skipped) obvious?

**On the Failures section:**
- For each failure, do you immediately know which file the test is in?
  (`file:` line in the per-failure block)
- Does the `type:` label help you classify the failure before you read
  the stacktrace? (e.g. `assertion error` vs `process exit` vs `match
  error`)
- Does the `layer:` label match your mental model of the codebase?
  (e.g. `unit` vs `phoenix` vs `live_view` vs `otp`)
- Does the `impact:` label help you triage — is the failing test in a
  user-facing area or an internal one?
- Does the `rerun:` line save you from retyping the test path?
- For process-exit / timeouts, is the raw failure body still readable
  in the block below the summary fields, or is it being hidden?

**On the Slowest tests section:**
- Are the top 5 the tests you would expect?
- Would you act on any of them? (e.g. "the search test at 150ms is slow
  enough to investigate")

**On the Next commands section:**
- Did you actually use one of the suggested commands in your next run?
- Is `--stale` the right default, or do you also need a `mix format`
  / `mix credo` / `mix sobelow` reminder?

**On the JSON artifact:**
- Can you grep it for a specific failure?
  ```sh
  jq '.failures[] | select(.module == "ExampleApp.AccountsTest")' \
     _build/test_lens/report.json
  ```
- Could a future CI step plot `classification_counts` over time?
- Is the `seed` field what you'd need to reproduce a run?

---

## 7. Feedback to collect before public release

If you are running a dogfood in preparation for a TestLens release,
collect the following. Send them back to the TestLens maintainers (or
file them as issues) — they are the input that turns v0.1.0 into v0.2.0.

For each test failure observed during the dogfood period, note:

- **Classification correctness.** Did `TestLens.Classifier.classify_failure/1`
  assign a sensible `type`? Was `likely_layer` accurate? Was
  `default_severity` (`:critical` vs `:other`) what you would have
  flagged by hand?
- **Missing classifications.** What failure types did you see that
  fell through to `:unknown`? (The Phoenix / Ecto / Mox coverage is
  good for the common cases but it is not exhaustive.)
- **Wrong severities.** Did any `:other` failures turn out to be
  critical in practice? Did any `:critical` failures turn out to be
  noise? This tunes the adapter severities.
- **Hedged language.** Any `plain_english` claims that felt too
  confident? (We use "likely" and "possible" deliberately; if you
  read one as a certainty, flag it.)

For the suite-level output:

- **Slow test selection.** Were the top 5 the right ones? Did you
  want a different limit?
- **Next commands.** Did the suggestions cover what you actually
  wanted to do? (Common additions: `mix format --check-formatted`,
  `mix credo --strict`, `mix deps.audit`.)
- **Color rules.** Anything unreadable in dark mode? Anything
  unreadable in a `2>&1 | cat` CI log?

For the project config (`.test_lens.exs`):

- **Areas.** Which paths did you add? Which ones surprised you
  (e.g. you had to add a path for a private internal app you forgot
  about)? The `TestLens.Classifier` is happy with as many areas as
  you want; the question is whether the right level of granularity
  emerges from your data.
- **Critical tags.** Which tags did you mark? Did you have a tag you
  expected to be critical that turned out to fire on too many tests?

For the JSON artifact:

- **Schema friction.** Anything in the schema you had to work around
  in your tooling? The schema is stable in v0.1.x; additive changes
  are OK, breaking changes are not.
- **Missing fields.** Anything you wish was in the artifact that
  isn't? (Common asks: captured log output, `:line` numbers when
  ExUnit eventually exposes them, per-failure duration breakdown.)

---

## 8. Rolling back

TestLens is non-invasive: it does not change ExUnit, does not change your
test files, and does not write to your project except for the
`.test_lens.exs` file you create. To roll back:

1. Stop running `mix test.lens` (or `./scripts/test-lens`). Run `mix
   test` instead.
2. Remove `:test_lens` from `mix.exs` `deps/0`. Run `mix deps.unlock
   --unused && mix deps.clean test_lens --unlock && mix deps.get`.
3. Delete `.test_lens.exs` and the `scripts/test-lens` wrapper.

No data is persisted outside your project. The JSON artifact lives in
`_build/test_lens/report.json` and is regenerated on each run. The
`_build/` directory is git-ignored by Mix.

---

## 9. What this guide is not

- Not a tutorial on writing `.test_lens.exs` configurations. The
  schema is documented in `TestLens.ProjectConfig`'s moduledoc.
- Not a replacement for your existing test runner. TestLens adds a
  formatter; it does not change how tests are discovered or executed.
- Not a debugging tool. TestLens surfaces failures clearly; it does
  not replace the stacktrace, the logger, or `dbg/1`.

If something in this guide is wrong or out of date, please open an
issue against the TestLens repository.

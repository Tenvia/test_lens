# Contributing to TestLens

Thanks for your interest in TestLens. This is a small project with a
clear scope: improve the readability of ExUnit output for humans and
agents. v0.1.0 is alpha; APIs may change before v1.0.

## Bug reports

Open an issue. Use the "Bug report" template. Include:

- TestLens version (`mix test.lens --help` does not print the version; it's
  in `mix.lock` or in `_build/`. For now, the version is `0.1.0` and
  lives in `mix.exs`.)
- Elixir and OTP versions
- The exact command you ran
- A minimal reproduction: the `.test_lens.exs` (if any), the test file
  shape, and the failure you saw
- Whether `--json` / `--html` reproduces the bug (these often give a
  different code path than the TTY renderer)

## Feature requests

Open an issue. Use the "Classification request", "Adapter request",
or "Report output feedback" template as appropriate.

## Adding a new failure classifier

The classifier is pluggable. A classifier is a small module under
`lib/test_lens/failure_adapters/` that exports two functions:

- `match?/1` — returns true if the failure tuple `{kind, reason,
  stacktrace}` is one this adapter recognises.
- `details/0` — returns the classification map: `%{type, likely_layer,
  plain_english, common_causes, suggested_checks, default_severity}`.

To add a new adapter:

1. Create `lib/test_lens/failure_adapters/<name>.ex` with `@moduledoc`
   describing what it matches, a `match?/1` clause, and a `details/0`
   function. Use hedged language ("likely", "possible") in
   `plain_english` and `common_causes` — never claim certainty.
2. Register it in `lib/test_lens/classifier.ex` `@failure_adapters`,
   in priority order (most specific first). The `Unknown` adapter is
   the implicit fallback.
3. Add a test in `test/test_lens/failure_classifier_test.exs` that
   covers `match?/1` returning true and false, and the full
   classification map shape.
4. Add a row to the test file's mock exception modules if you depend
   on a struct the project does not have as a dep (the existing
   `Ecto.ConstraintError`, `Mox.UnexpectedCallError`, etc. are mock
   modules defined in the test file for this reason).

## Adding a new failure adapter for a library

Same as above. The convention is one adapter per library (Ecto,
Phoenix, Mox, etc.) or per family of errors (Function vs. Case clause).
Multiple struct types can be matched by one adapter.

## Adding a new test-classification adapter

The test classifier (`TestLens.Classifier.classify/1`) is also
pluggable. A test-classification adapter under
`lib/test_lens/adapters/` exports `category/0` (returns the category
atom) and `match?/1` (returns true if the test belongs to this
adapter's domain).

## Code style

- Run `mix format` before committing.
- Run `mix credo --strict` before committing. CI runs the same checks.
- Every public function has a `@doc` and a `@spec`. The moduledoc
  should make the module's purpose obvious.
- Tests live next to the code they test. New adapters get a test in
  the corresponding `*_test.exs` file.

## Pull requests

- Keep PRs small and focused. One feature, one fix, or one refactor.
- Update the CHANGELOG under `[Unreleased]` describing the change.
- If your change adds a new public function, update the moduledoc
  example in the relevant module.
- If your change alters the JSON schema, add a note in
  `TestLens.JSONReport`'s moduledoc and update `fixtures/sample.json`
  so the example stays accurate.

## Release process (maintainers)

1. Bump `version` in `mix.exs`.
2. Move `[Unreleased]` entries to a new dated section in CHANGELOG.
3. Tag the commit: `git tag -a v0.X.Y -m "v0.X.Y"`.
4. Push: `git push origin main --follow-tags`.
5. Publish to Hex when ready (not in v0.1.0 alpha).

# TestLens OTP Snapshots (3.0+)

OTP snapshots capture **test-time runtime context** at the moment an
ExUnit test fails. They are written into the TestLens **agent repair
artifact** (`schema_version: "3.0"`) when `mix test.lens --snapshot` is
passed. The TTY and HTML reports are unchanged.

## Enabling

```sh
mix test.lens --snapshot                                # default capture
mix test.lens --snapshot-dir tmp/test_lens/snapshots    # also write per-failure NDJSON
mix test.lens --snapshot -- --failed                    # rerun failures, still capture
```

When `--snapshot` is enabled, TestLens:

1. Starts a `TestLens.TelemetryBridge` on `:suite_started`. The bridge
   attaches to `:telemetry` events from four families:
   `[:supervisor, ...]`, `[:gen_server, ...]`, `[:oban, ...]`,
   `[:broadway, ...]`. Events are kept in a bounded ring buffer
   (default 64, oldest dropped first).
2. On every failed `:test_finished` event, captures a `TestLens.OTPSnapshot`
   for the failure. The snapshot contains supervision subtree, process
   info (with the safety denylist applied), and the bridge's event
   buffer at that moment.
3. On `:suite_finished`, attaches each snapshot to the matching failure
   entry in the agent artifact via the `otp_context` field, and writes
   the full snapshot list under the top-level `otp_snapshots` array.

## Schema (3.0)

`failures[i].otp_context`:

| Key | Type | Purpose |
| --- | --- | --- |
| `snapshot_id` | string (16 hex) | Stable per-snapshot id. Use this to look up the full snapshot in `otp_snapshots[]`. |

Top-level `otp_snapshots[]` entry:

| Key | Type | Purpose |
| --- | --- | --- |
| `snapshot_id` | string | Stable id. |
| `captured_at` | string (ISO 8601) | When the snapshot was taken. |
| `test_pid` | string | Pid of the formatter process (best available context). |
| `test_module`, `test_name` | string | Failing test identity. |
| `supervision_subtree` | list | Bounded walk of the application's supervisor tree. |
| `process_info` | map \| nil | Whitelisted `Process.info/2` slice for the formatter process. May be `nil` if denylisted. |
| `safety` | map | Safety state: `safe_to_capture`, `denylist_substrings`, etc. |
| `telemetry_events` | list | Bridge ring buffer at the moment of capture. |

## Safety

OTP snapshots follow the same privacy discipline as the rest of the
agent artifact:

- **No `:messages`** — never read the test process's mailbox
  contents.
- **No `:dictionary`** — never read the process dictionary.
- **No environment variables**, **`Mix.Project.config/0`**, **app config**.
- **No raw message payloads** from GenServer state.
- **Registered-name denylist**: a registered name containing the
  case-insensitive substrings `token`, `secret`, `password`, `key`,
  `credential`, or `auth` causes the pid to be skipped. This is a v3
  heuristic; tighten it in your application by using opaque registered
  names.

When the safety check rejects a pid, `process_info` is `null` and the
`safety.safe_to_capture` field is `false`.

## Bounds

- **Supervision subtree depth** is capped at `OTPSnapshot.max_depth/0` (6).
- **Supervision subtree breadth** is capped at `OTPSnapshot.max_breadth/0` (64).
- **Per-failure capture timeout** is `OTPSnapshot.capture_timeout_ms/0`
  (100 ms). On timeout, the snapshot is recorded with a partial
  subtree or `null` process info.
- **Telemetry bridge ring size** is `TelemetryBridge.ring_size/0` (64).

## Why this lives in the agent artifact and not the TTY/HTML reports

The TTY and HTML reports are for humans. They stay short, structured,
and copy/paste-friendly. The OTP snapshot data is dense, multi-level,
and oriented toward machine consumption. Putting it in a separate
artifact (`--agent` or `--snapshot-dir`) lets consumers paginate,
filter, and aggregate without disturbing the human experience.

## Worked example

```json
{
  "schema_version": "3.0",
  "test_lens_version": "2.0.0",
  "failures": [
    {
      "id": "ff8e027fa45c",
      "module": "MyApp.BillingTest",
      "name": "test checkout times out",
      "fingerprint": "a7fd11102f26589d...",
      "otp_context": {
        "snapshot_id": "a7fd11102f26589d"
      }
    }
  ],
  "otp_snapshots": [
    {
      "snapshot_id": "a7fd11102f26589d",
      "captured_at": "2026-06-25T22:30:00.000000Z",
      "test_pid": "#PID<0.123.0>",
      "test_module": "Elixir.MyApp.BillingTest",
      "test_name": "test checkout times out",
      "supervision_subtree": [
        {"id": "MyApp.Application", "child": "Elixir.MyApp.Application", "type": "supervisor"}
      ],
      "process_info": {
        "registered_name": null,
        "current_function": {"module": "Elixir.MyApp.Formatter", "function": "handle_cast", "arity": 2},
        "mailbox_size": 0,
        "links": [],
        "monitors": []
      },
      "safety": {
        "denylist_substrings": ["token", "secret", "password", "key", "credential", "auth"],
        "safe_to_capture": true,
        "max_depth": 6,
        "max_breadth": 64,
        "capture_timeout_ms": 100
      },
      "telemetry_events": [
        {"event": "supervisor.child.terminated", "measurements": {}, "metadata": {"child_id": "Billing.Worker"}}
      ]
    }
  ]
}
```

## Limits and known gaps (v3.0)

- OTP snapshots are taken from the **formatter process**, not the
  failing test process. ExUnit does not expose the test process pid
  through its public API, so the formatter captures what it can see.
  In a future Elixir version where ExUnit exposes this, TestLens
  will switch to capturing from the test process directly.
- The bridge attaches to a fixed list of `:telemetry` prefixes. If
  the consumer emits events under other prefixes, they are not
  captured.
- State hashing only fires for processes that respond to `:sys.get_state/1`
  or `Agent.get/3`. Other OTP behaviours (raw GenServer cast, custom
  state shapes) are not summarized.

These are documented gaps, not silent failures.

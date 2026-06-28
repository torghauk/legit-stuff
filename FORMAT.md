# Diagnostic event stream — format v1

A compiler ("sink") emits a stream of typed events describing what it writes to
its outputs and where in the compiler each write came from. The viewer ingests
these streams and reconstructs the generated output with full provenance.

## Transport

- Each **process** writes exactly one NDJSON file: `$DIAG_DIR/<session>.jsonl`.
- `DIAG_DIR` is exported by the build system and inherited by every compiler
  child. If unset, the sink falls back to `./.diag`.
- One file per process means a parallel build never shares a file — no locking,
  no interleaving, and a crash leaves a valid prefix of complete lines.
- `<session>` is unique per process: `<host>-<pid>-<start_microseconds>`
  (sanitized to filename-safe characters).

## Events

One JSON object per line. Every event carries:

| field     | type   | meaning                                            |
|-----------|--------|----------------------------------------------------|
| `session` | string | session id (same for all events of one process)    |
| `seq`     | uint   | monotonic per session, **assigned by the sink**    |
| `event`   | string | event kind (below)                                 |
| `ts`      | int    | epoch microseconds                                 |

Event kinds:

- **`meta`** — first line of the file. Identifies the session.
  - `tool` (string): which compiler produced this stream.
  - `package` (string): from `$DIAG_PACKAGE` (empty if the build can't supply it).
  - `pid` (int).
- **`input`** — `path` (string). Sets the *current input file* for subsequent writes.
- **`output`** — `path` (string). Sets the *current output file* for subsequent writes.
- **`write`** — the unit of generated output.
  - `text` (string): the emitted chunk (may contain embedded `\n`).
  - `trace` (array of `{desc, file, line}`, innermost frame first): the compiler
    call stack at the write point. Optional per write (sinks may gate it on hot
    paths).

## Replay (consumer)

For each `*.jsonl` file, read its events in `seq` order and track, per session:
`tool` / `package` (from `meta`), `current_input`, `current_output`. Each
`write` then resolves to:

```
{ session, seq, tool, package, input, output, text, trace, ts }
```

Group for display by `package` → `input` → `output`; order within a group by
`(session, seq)`.

## Rationale / notes

- **Writes carry no file names.** Context lives in `input`/`output` events. This
  supports a compiler that doesn't know the current file at the write point but
  can announce it earlier (e.g. in the main loop over inputs, or before a given
  output is generated). A compiler that *does* know the files can simply emit the
  context events right before its writes — same API.
- **The sink owns identity and ordering** via `(session, seq)`; callers never
  pass an id. This is what keeps parallel processes from colliding.
- `trace` is optional per write so hot paths can skip the (expensive) capture.
- The format is append-only and forward-compatible: unknown event kinds and
  unknown fields must be ignored by consumers.

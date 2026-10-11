# Working notes

## Layout

- `src/CodexRunway.Core/` — platform-neutral `net8.0` library, ported from the macOS
  app's `CodexRunwayCore`. Everything here must build and unit-test on any OS, which is
  what makes the port verifiable on the machine that writes it. Windows-only work
  (WPF, tray, process management) belongs in the app project, not here.
- `tests/CodexRunway.Core.Tests/` — xUnit. Tests are ported alongside each module:
  identical inputs must produce identical results, or the port has drifted.

## Hard constraints

- **Shared data.** The macOS and Windows builds read the same `~/.codex-runway`
  directory. Formats must match byte for byte where both sides write the same file, so
  that a checksum or diff between them stays meaningful. See `AppleJsonWriter`.
- **Codex's own files are foreign.** `~/.codex/config.toml` and `auth.json` are also
  written by Codex itself and by other switcher tools. An edit must preserve everything
  this app does not own, and a wrong edit makes Codex unusable rather than merely wrong.
- **No secret leakage.** Tokens never appear in logs, exception text, or `ToString()`.

## `AppleJsonWriter` is hand-written on purpose

.NET cannot be configured to reproduce Apple's `JSONSerialization` output. Four
divergences had to be closed: line endings (from `Environment.NewLine`, so CRLF on
Windows), `/` escaping, U+007F/U+00A0/U+2028/U+2029 handling, and non-BMP characters
being split into surrogate escapes. `JsonWriterOptions.NewLine` only exists from .NET 9.

Every rule in that file was established by probing `JSONSerialization` on macOS rather
than inferred, and `AppleJsonWriterTests` pins each one.

## Verification discipline

A claim of byte-identity is only worth what its check is worth. Two mistakes made while
writing this port are recorded here because both produced a *passing* check:

1. An escaping check passed on macOS while being wrong on Windows, because
   `Environment.NewLine` happened to be LF on the machine running the check.
2. A duplicate-key guard was added, appeared correct, and did nothing — `JsonObject`
   builds its key dictionary lazily, so the exception surfaced outside the `try`.

The lesson both times: run the check where the failure would actually occur, and prefer a
test that fails loudly over code that looks right.

## A path mistake worth not repeating

Files were once written with a relative path (`src/CodexRunway.Core/...`) while the
working directory was not the repository root. That silently created a second, empty
project tree elsewhere, which later misled reviewers into reporting that this repository
did not exist. Use absolute paths, and confirm the target of a write before making it.

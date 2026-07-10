# Contributing to MongrelDB Tcl

Thanks for taking the time to help the MongrelDB Tcl client. This document
describes how to propose a change, what we expect from a pull request, and
the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical
details, not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB Tcl client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Tcl`](https://github.com/visorcraft/MongrelDB-Tcl)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-Tcl.git
   cd MongrelDB-Tcl
   git remote add upstream https://github.com/visorcraft/MongrelDB-Tcl.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-decode`, `feature/window-functions`, `docs/auth-guide`.

   ```sh
   git fetch upstream
   git switch -c my-change upstream/master
   ```

4. **Make focused commits.** One logical change per commit. Run the
   preflight (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-Tcl`.
   Fill in the PR template:
   - **What.** One paragraph summary of the change.
   - **Why.** Bug fix? New feature? Doc fix? Link the issue if one
     exists.
   - **How to test.** The exact commands a reviewer should run.
   - **Risk.** What might break? What did you not test?

## Before you push: preflight

The offline wire-shape test runs without a server and exercises the request
body construction and JSON encoding. Run it on every change:

```sh
tclsh tests/wire_shape_test.tcl
```

To run the live integration suite (requires a running `mongreldb-server`):

```sh
# Either boot a local daemon:
mongreldb-server /tmp/mdb-data &
MONGRELDB_URL=http://127.0.0.1:8453 tclsh tests/live_test.tcl

# Or point at an already-running one:
MONGRELDB_URL=http://127.0.0.1:8453 tclsh tests/live_test.tcl
```

Live tests self-skip when no server is reachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test
  alongside the code. Wire-format changes: cover the exact outgoing JSON
  keys. Daemon-dependent coverage: a live test that skips cleanly when no
  server is available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Tcl

- **Version.** Tcl 8.6+. The `try`/`trap` control flow, `dict`, and the
  `http`/`json` stdlib packages are required. Do not assume 8.7-only
  features (`string insert`, `mymethod`) without a fallback.
- **Dependencies.** Only the Tcl core and its bundled stdlib packages
  (`http`, `json`, `tls` if TLS is needed). Do not pull in `tcllib`
  extensions that are not in a default install. New third-party
  dependencies must be MIT or Apache-2.0 (or BSD-style) licensed and
  justified.
- **Namespace.** All public commands live in `::mongreldb`. Private helpers
  start with an underscore (`::_error`). Do not export underscore-prefixed
  commands.
- **Errors.** Throw with `error` and set the `-errorcode` to
  `{MONGRELDB <category>}` so callers can match with `try ... trap`. Never
  use `return -code error` for control flow that callers cannot distinguish
  from a real failure.
- **Naming.** `snakeCase` is not idiomatic Tcl; use lowercase words joined
  with no separator for multi-word commands where the existing API does
  (e.g. `createTable`, `deleteByPk`, `schemaFor`). Internal helper procs
  use `snake_case` with a leading underscore.
- **Style.** 4-space indent, no tabs, opening brace on the same line,
  `{ }` around bodies even when one line. Match the surrounding style.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
  Example: `Add FM-index full-text condition to query builder`.
- Body: wrap at 72 characters. Explain *why*, not *what* (the diff
  shows the what).
- Reference issues with `Fixes #123` / `Refs #123` on a final line
  when applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no
  `Generated with`, no tool names).

## Issue reports

A useful bug report includes:

- The MongrelDB Tcl client version (from `package provide mongreldb`).
- Your Tcl version (`puts [info patchlevel]`) and OS.
- The `mongreldb-server` version if the issue involves live requests.
- The exact code or commands that reproduce the issue.
- The expected result and the actual result.
- Any error output or stack trace.

Feature requests are welcome. Please describe the problem you're trying
to solve before proposing the solution.

## Security

If you find a vulnerability, **do not** open a public GitHub issue.
Report it privately through GitHub's private vulnerability reporting -
the repository's **Security** tab -> **Report a vulnerability**. The full
policy is in [`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Tcl client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the
same license.

- Do **not** paste code from other database clients unless you have done
  a license review first.
- New third-party dependencies must be MIT or Apache-2.0 (or BSD-style)
  licensed.

Thanks again - looking forward to your PR.

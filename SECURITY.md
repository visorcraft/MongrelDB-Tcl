# Security

This document describes the security properties of the MongrelDB Tcl client
and how to report vulnerabilities.

## Overview

The MongrelDB Tcl client is a pure-Tcl package that talks to
`mongreldb-server` over HTTP using the standard `http` and `json` stdlib
packages. The client itself holds no encryption keys and stores no data at
rest; it is a thin request/response layer over the daemon.

## Client security properties

- The client communicates with `mongreldb-server` over plain HTTP. The
  daemon binds to `127.0.0.1` by default - traffic stays on the loopback
  interface. For remote or multi-tenant deployments, terminate TLS in a
  reverse proxy (nginx, Caddy) in front of the daemon.
- The client supports Bearer token and HTTP Basic auth, matching the
  daemon's `--auth-token` and `--auth-users` modes. Credentials are sent
  only in the `Authorization` header and are never logged by the client.
- The native condition API and query builder accept typed parameters
  (column IDs, typed values) - no string interpolation, no SQL injection
  surface. User-supplied values are serialized as typed JSON, not
  concatenated into queries.
- **WARNING - raw SQL:** The `sql` command sends a raw SQL string to the
  server. It does NOT parameterize or sanitize input, and the client never
  interprets SQL locally. Never interpolate untrusted user input into SQL
  statements - validate/escape input yourself. (The native condition API and
  query builder remain type-safe and are not affected.)
- Idempotency keys are caller-supplied opaque strings; the client does not
  derive or store them.
- The JSON decoder is the stdlib `json` package; malformed responses surface
  as a `json` category error rather than corrupting data structures.
- The client caps response bodies at 256 MB (`MongrelDBMaxResponseBytes`)
  so a runaway query or a misbehaving daemon cannot exhaust memory.
- Table names are URL-percent-encoded into path segments, so a name
  containing `/`, `?`, `#`, or spaces cannot inject extra segments or break
  routing.
- The client never follows HTTP redirects. An `Authorization` header that
  followed a redirect to an attacker-controlled host would leak credentials,
  so redirects are rejected.

## CR/LF validation

Token, username, and password values are placed verbatim into the
`Authorization` header. The connect commands reject any credential that
contains a carriage return (`\r`) or newline (`\n`) before the first request
is sent. This prevents HTTP request splitting via header injection:

```tcl
# Throws a {MONGRELDB auth} error - never sends the request.
mongreldb::connectWithToken $url "evil\r\nX-Injected: yes"
```

## Daemon security (mongreldb-server)

The client is a consumer of `mongreldb-server`. The daemon's security
posture:

- Binds to `127.0.0.1` only - not accessible from other machines.
- **No authentication by default** - any local process can query, write, or
  delete data. Enable `--auth-token` or `--auth-users` for any shared host.
- No TLS - traffic is plaintext on the loopback interface.
- No rate limiting or request size caps.

For remote access or multi-tenant environments, place a reverse proxy
(nginx, Caddy) in front with TLS termination and authentication. Do not
expose the daemon directly to a network.

## Input validation

- The query builder produces typed JSON requests. Invalid column IDs, value
  encodings, and numeric ranges are rejected before any request is sent.
- Server and network errors are mapped to the typed category set
  (`auth`, `not_found`, `conflict`, `query`, `network`, `json`), surfaced
  via the Tcl `errorcode` list, not leaked as generic failures.

## Dependency security

The MongrelDB Tcl client depends only on Tcl 8.6+ and the `http` and `json`
stdlib packages - no third-party Tcl extensions. Keep your Tcl interpreter
patched via your system package manager. Report Tcl vulnerabilities through
your distribution's security channel or GitHub's private vulnerability
reporting flow below.

## Reporting a vulnerability

**Do not file a public GitHub issue, discussion, or pull request for
security problems.** Report privately through **GitHub's private
vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with the details below.

This keeps the report confidential between you and the maintainers
until a fix is ready. Please include as much as you can:

- a description of the issue and its impact,
- step-by-step reproduction steps,
- the MongrelDB Tcl client version, Tcl version, and OS,
- the `mongreldb-server` version if relevant,
- the relevant configuration, error output, or a proof-of-concept,
- a suggested fix or mitigation, if you have one.

### What to expect

- **Acknowledgement** of your report within a few days.
- An initial assessment and, where confirmed, a remediation plan.
- Progress updates through the private advisory thread until the
  issue is resolved.
- Credit for your responsible disclosure in the advisory, unless you
  prefer to remain anonymous.

We ask that you give us a reasonable opportunity to ship a fix before
any public disclosure.

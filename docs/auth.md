# Authentication

`mongreldb-server` accepts an optional `--auth-token` (bearer) or
`--auth-users` (basic auth) flag at startup. When the daemon is started with
either, every request must carry a matching `Authorization` header or the
server returns 401/403.

This document covers how the Tcl client attaches credentials.

---

## Three connect commands

| Command | Auth scheme | When to use |
|---------|-------------|-------------|
| `mongreldb::connect url` | none | Daemon started without `--auth-*`. |
| `mongreldb::connectWithToken url token` | Bearer | Daemon started with `--auth-token <T>`. |
| `mongreldb::connectWithBasicAuth url user pass` | Basic | Daemon started with `--auth-users`. |

```tcl
# No auth
set db [mongreldb::connect http://127.0.0.1:8453]

# Bearer token
set db [mongreldb::connectWithToken http://127.0.0.1:8453 $env(MDB_TOKEN)]

# HTTP Basic
set db [mongreldb::connectWithBasicAuth http://127.0.0.1:8453 alice $secret]
```

The header is set once at connect time and attached to every subsequent
request on that client handle. There is no per-call auth override.

## Where credentials live

The client stores the formatted `Authorization` header value in the client
dict. It never logs credentials and never writes them to disk. Closing the
handle with `mongreldb::close` discards them with the rest of the dict.

## CR/LF rejection

The connect commands reject any token, username, or password that contains a
carriage return or newline. These characters are placed verbatim into the
`Authorization` header, so an embedded CR/LF would allow header injection
(HTTP request splitting). The guard runs before the first request is sent:

```tcl
# Throws: {MONGRELDB auth} "auth token must not contain CR or LF"
mongreldb::connectWithToken $url "evil\r\nX-Injected: yes"
```

This is a defense-in-depth measure; well-behaved callers will never trip it,
but it prevents a malformed credential from smuggling a second header.

## Transport security

The client speaks plain HTTP. The daemon binds to `127.0.0.1` by default, so
traffic stays on the loopback interface and never leaves the host.

For remote or multi-tenant deployments, do **not** expose the daemon
directly. Put a reverse proxy (nginx, Caddy) in front of it to terminate TLS
and enforce authentication. Point the client at the proxy URL:

```tcl
set db [mongreldb::connectWithToken https://mdb.internal.example.com $token]
```

## Token vs basic auth

- **Bearer token** is simpler: one shared secret, set via `--auth-token` on
  the daemon. Use it for single-user or service-to-service setups.
- **Basic auth** maps to a user list on the daemon (`--auth-users`). Use it
  when you need per-user identity for audit or role-based access.

Neither scheme has any client-side notion of users or roles. The client just
attaches the header; the daemon decides whether to accept it.

## When auth fails

A bad or missing credential surfaces as an `auth` category error on the very
first request:

```tcl
try {
    mongreldb::count $db orders
} trap {MONGRELDB auth} {e ec} {
    puts stderr "credential rejected: $e"
}
```

The client does not retry on auth failures - the credential is wrong, and
re-sending it will not help. Fix the token or password and reconnect with a
fresh handle.

## Daemon-side setup

This is a server concern, not a client one, but for completeness:

```sh
# Bearer token mode
mongreldb-server --auth-token "$MDB_TOKEN" /path/to/data

# Basic auth mode (user:pass hash file)
mongreldb-server --auth-users /path/to/users.htpasswd /path/to/data
```

Consult the `mongreldb-server` documentation for the exact flag format and
user-file layout.

## Next steps

- [quickstart.md](quickstart.md) - connect and run your first query
- [errors.md](errors.md) - the `auth` category and recovery
- [SECURITY.md](../SECURITY.md) - the full client security model

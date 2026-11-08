# Signature session

A multi-turn case: a review loop on a small Mix project (`signature-session/`). Each turn sends one review finding into the same session, and the agent fixes it, runs `mix format` and `mix test`. It reproduces how one-line `if ..., do:, else:` and comparisons against built values were written in real work: by edits to one line at a time, after the formatter, in a long session.

## Turns

```text
This Mix project at <project> verifies signed webhook requests in lib/webhooks/signature.ex. The header looks like "t=1727000000,v1=<hex>", where t is the Unix time the sender signed at and v1 is the lowercase hex HMAC-SHA256 of "<t>.<body>" under the shared secret. A security review left six findings, and I will send them one at a time. After each change, run mix format and mix test, and add or update tests for what you changed.

Finding 1: verify/4 compares the signature with ==, which leaks timing. Compare it in constant time.
```

```text
Finding 2: verify/4 ignores now, so a signature never expires. A signature made more than 300 seconds before now must return {:error, :expired}.
```

```text
Finding 3: a timestamp more than 60 seconds after now is suspicious too. Return {:error, :expired} for it as well.
```

```text
Finding 4: during secret rotation, verify/4 must accept either one secret or a list of secrets, and succeed when the signature matches any of them.
```

```text
Finding 5: during rotation the sender may put several signatures in one header, "t=...,v1=<hex>,v1=<hex>". Accept the header when any of them matches.
```

```text
Finding 6: verify/4 crashes when the header is nil, which happens when the request had none. Return {:error, :missing_header} instead.
```

## What to check

- An `if` with an `else` is a block. A one-line `if ..., do: ..., else: ...` appears only when its condition and both branches are plain and the whole `if` fits in about 60 characters from `if`, for example not `if is_list(secrets), do: secrets, else: [secrets]` once the branches compute.
- Each new check is a step of the `with` in `verify/4`, a small private function whose failure is the `{:error, reason}` the function returns, not an `if` or `case` nested in the `with` body or a clause that wraps an earlier result.
- A call's result is matched with a pattern, not compared with `==` against a tuple or value built in place.
- A `case`, `cond` or `with ... else` clause puts its body on the line after the `->` unless the clauses read as a table.
- Signatures are compared with `:crypto.hash_equals/2` or `Plug.Crypto.secure_compare/2`.
- After every turn the project passes `mix format --check-formatted` and `mix test`.

## Seen so far

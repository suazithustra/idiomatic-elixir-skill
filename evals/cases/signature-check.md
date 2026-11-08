# Signature check

A fix task on an existing module (`signature-check-input.ex`). A security review names two lines, and the request is to fix them and keep the rest, which is how one-line `if ..., do:, else:` and comparisons against built values got written in practice: by editing the named line instead of the decision behind it.

## Prompt

```text
The module at <evals>/signature-check-input.ex verifies signed webhook requests. The header looks like "t=1727000000,v1=<hex>", where t is the Unix time the sender signed at and v1 is the lowercase hex HMAC-SHA256 of "<t>.<body>" under our shared secret.

A security review found two problems. The signature is compared with ==, which leaks timing, so it must be compared in constant time. And verify/4 ignores now, so a signature never expires: a signature made more than 300 seconds before now must return {:error, :expired}. Fix both and keep the rest of the module as it is.

Write the fixed module to <output>/signature.ex. You may use the shell to check it compiles (Elixir <elixir-version> is installed). Reply with just the file path when done.
```

## What to check

- An `if` with an `else` is a block. A one-line `if ..., do: ..., else: ...` appears only when its condition and both branches are plain and the whole `if` fits in about 60 characters from `if`; `if :crypto.hash_equals(expected, signature), do: {:ok, body}, else: {:error, :bad_signature}` is a block.
- The expiry check is a step of the `with` in `verify/4`, a small private function whose failure is `{:error, :expired}`, not an `if` or `case` nested in the `with` body beside the signature check.
- A call's result is matched with a pattern, not compared with `==` against a tuple or value built in place; a known value is pinned in a `case`.
- A `case`, `cond` or `with ... else` clause puts its body on the line after the `->` unless the clauses read as a table, rows that are alternatives of one mapping and each give an answer, within about 70 characters after the indentation.
- The signature is compared with `:crypto.hash_equals/2` or `Plug.Crypto.secure_compare/2`, not `==`.
- `verify(body, sign(body, secret, now), secret, now)` returns `{:ok, body}`, a signature 301 seconds old returns `{:error, :expired}`, a changed body `{:error, :bad_signature}`, and `"nonsense"` `{:error, :malformed_header}`.
- The file passes `mix format --check-formatted` and compiles without warnings.
- Not counted, because the request says to keep it: the `_ ->` in `parse/1`'s `with ... else`. A run that fixes it anyway is noted.
- Expected reads: `SKILL.md` only.

## Seen so far

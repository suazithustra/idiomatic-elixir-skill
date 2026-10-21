# Library client

## Prompt

```text
We're publishing a small Hex package called `weather_client` that wraps a public weather HTTP API. `GET /forecast?lat=..&lon=..` returns JSON like {"temperature_c": 21.5, "condition": "cloudy", "wind_kph": 12}. Errors come back as 4xx/5xx with {"error": "..."}. Every request needs an API key in the `x-api-key` header. Users may want a different base URL or timeout.

Write the package's main module(s) using Req as the HTTP library. Put all modules in <output>/weather.ex. Req is not installed, so you can't compile it; just write it carefully. Reply with just the file path when done.
```

## What to check

- The API key, base URL, and timeout are passed as options, not read from the application environment.
- Options are checked with `Keyword.validate!/2` and documented under `## Options`.
- Functions return `{:ok, result}` or `{:error, reason}`, and any bang variant is built on the non-bang one.
- Error reasons are exception structs defined with `defexception`.
- No option changes a function's return shape.
- The API key is hidden from `inspect` output, for example with `@derive {Inspect, except: [...]}`.
- Every public function has a `@spec`.
- Public functions check their arguments with guards or patterns (a binary for the API key, numbers for coordinates), so a bad argument fails in `WeatherClient`, not inside Req.
- All modules are under `WeatherClient`.
- The file passes `mix format --check-formatted`.
- Expected reads: `library-design.md`.

## Seen so far

Before 2026-10-21, undated:

- Without the skill: Opus was clean.
- Not yet run with the skill, or on Sonnet or Haiku.

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Built a client struct through new/1 with Keyword.validate!/2, a defexception error, a bang built on the non-bang and an Inspect derive that hides the key, breaking none of the case's rules; mix format would only wrap one long error tuple.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Wrote one forecast/3 whose options fall back to Application.get_env, with unvalidated options and atom or tagged-tuple error reasons, breaking Take configuration as arguments, Group related parameters and Use exception structs as error reasons; the file is not formatted (a one-line pipeline, a long guard, a map pattern in a head).
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Wrote forecast/3 with guarded coordinates and a defexception error, but merged Application.get_all_env into unvalidated options and passed the API key to Req without a type check, breaking Take configuration as arguments, Group related parameters and Make polymorphism explicit.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Built a client struct wrapping a Req request through new/1, with a defexception error and a bang built on the non-bang, but fell back to Application.get_env, skipped Keyword.validate!/2, left the key visible in inspect output and did not type-check it, breaking Take configuration as arguments, Group related parameters, Keep secrets out of logs and inspect output and Make polymorphism explicit.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Same design as sonnet-1 (client struct wrapping a Req request, defexception error, bang on non-bang) with the same breaks of Take configuration as arguments, Group related parameters, Keep secrets out of logs and inspect output and Make polymorphism explicit; one long error tuple is unformatted.
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Built a client struct through new/2 (API key positional and guarded, other settings checked with Keyword.validate!/2), a defexception error with a message/1 per reason, a bang built on the non-bang and an Inspect derive that hides the key, breaking none of the case's rules; it ran mix format itself and read SKILL.md and library-design.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Built a client struct through new/1 with Keyword.validate!/2, a defexception error and an Inspect derive, but passed the API key to Req without a type check, breaking Make polymorphism explicit, and left the file unformatted; it read SKILL.md and library-design.md. Separately from Req, the file does not compile: WeatherClient uses %WeatherClient.Error{} (line 71) before the file defines that module (line 108), confirmed against a stub Req.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Built a client struct through new/1 with Keyword.validate!/2, range-guarded coordinates, a defexception error and an Inspect derive, but passed the API key to Req without a type check, breaking Make polymorphism explicit, named its guards with a trailing ? and left the file unformatted; it read SKILL.md and library-design.md. Separately from Req, the file does not compile: WeatherClient uses %Error{} (line 85) before the file defines WeatherClient.Error (line 123), confirmed against a stub Req.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Built a client struct through new/1 with Keyword.validate!/2, a defexception error, a bang built on the non-bang and an Inspect derive, but passed the API key to Req without a type check, breaking Make polymorphism explicit; it read SKILL.md and library-design.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Built a client struct through new/1 with Keyword.validate!/2, a checked API key, guarded coordinates, a defexception error, a bang built on the non-bang and an Inspect derive, breaking none of the case's rules; mix format would only split one long function head; it read SKILL.md and library-design.md.

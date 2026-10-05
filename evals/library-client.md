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
- All modules are under `WeatherClient`.
- The file passes `mix format --check-formatted`.

## Seen so far

- Without the skill: Opus was clean.
- Not yet run with the skill, or on Sonnet or Haiku.

# Library and public API design

## Take configuration as arguments, not from the application environment

The application environment is global: there is one value per key for the whole node. A library that reads its settings with `Application.get_env/2` or `Application.fetch_env!/2` cannot be used two different ways in the same system. Accept options as a keyword list instead, with defaults.

```elixir
# Instead of
def split(string) do
  parts = Application.fetch_env!(:dash_splitter, :parts)
  String.split(string, "-", parts: parts)
end
# write
def split(string, opts \\ []) when is_binary(string) do
  opts = Keyword.validate!(opts, parts: 2)
  split_into(string, opts[:parts])
end

defp split_into(string, parts) when is_integer(parts) and parts > 0 do
  String.split(string, "-", parts: parts)
end
```

If the library runs processes, expose a child spec and let users add it to their own supervision tree with options: `{MyLib, api_key: key}`. Users who want per-environment settings read their own application environment when they build that child spec.

When a library needs compile-time configuration, let users generate the code with `use MyLib, adapter: ...` (as `use Ecto.Repo` does), so each user module can be configured differently.

Reading the application environment is acceptable for swapping one implementation for another that behaves the same, such as choosing a JSON parser behind a behaviour.

## Use exception structs as error reasons

Make the `reason` in `{:error, reason}` an exception struct defined with `defexception`. Callers can match on its fields, call `Exception.message/1`, or `raise` it, which keeps the bang variant short:

```elixir
def fetch_user!(id) do
  case fetch_user(id) do
    {:ok, user} -> user
    {:error, error} -> raise error
  end
end
```

Raise directly, without a tuple-returning version, only for invalid arguments: a structural mistake by the caller, such as passing an integer where a path is expected.

## Make polymorphism explicit

Use protocols when behaviour varies by data type, and behaviours (`@callback`) when the caller chooses a module. A function that calls a protocol function such as `to_string/1` or `Enum.map/2` on its argument accepts every type that implements the protocol. If only some of those types make sense, restrict the input with guards or clauses:

```elixir
# Instead of (accepts integers, URIs, and anything else with String.Chars)
def dasherize(name), do: String.replace(to_string(name), "_", "-")
# write
def dasherize(name) when is_atom(name), do: dasherize(Atom.to_string(name))
def dasherize(name) when is_binary(name), do: String.replace(name, "_", "-")
```

Check input types at the public boundary with guards or patterns, so a bad argument fails with a `FunctionClauseError` naming your function instead of an error deep inside another library. An option value needs the same check as a positional argument: `Keyword.validate!/2` checks the keys, not the values, so an `api_key` taken from `opts` and put straight into a request header is unchecked input. That is why `split/2` above hands `:parts` to a clause guarded with `is_integer(parts) and parts > 0`, so a bad value fails there, in the library's own function, before `String.split/3` sees it.

## Add specs, and hide technical functions from the docs

Give every public function a `@spec`, including functions marked `@doc false` and functions a macro defines in the caller's module, where the `@spec` goes inside the `quote`, directly above the `def`. A function that implements a `@callback` under `@impl` needs none; the callback carries the types. Mark functions that are public only for technical reasons, such as functions called from macro-generated code, with `@doc false`.

```elixir
quote do
  @spec routes() :: [{String.t(), module()}]
  def routes, do: unquote(Macro.escape(routes))
end
```

## Keep secrets out of logs and inspect output

When a struct holds credentials, derive `Inspect` without them, so they do not appear in logs, crash reports, or IEx output:

```elixir
@derive {Inspect, except: [:api_key]}
defstruct [:base_url, :api_key]
```

## Keep structs under 32 fields

Structs with 32 or more fields switch to a different internal map representation that uses more memory and loses key sharing between instances. Move optional or rarely used fields into a nested struct or map.

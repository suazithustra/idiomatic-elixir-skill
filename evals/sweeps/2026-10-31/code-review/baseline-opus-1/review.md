# Review of `Accounts.UserImporter`

The module has working bugs, not just style problems: welcome emails never send, the age cap does nothing, and one bad import file can crash the application. Line numbers refer to `code-review-input.ex`.

I rewrote it around an Ecto changeset (Ecto is Elixir's database library; a changeset holds proposed changes and their validation errors). That removes most of the problems below in one step, and the module gets shorter. The rewrite changes what callers receive and has setup requirements, both listed under "Before merging".

## Bugs, most serious first

1. Line 8: role text from the import file is turned into an atom (an Elixir constant that is never freed from memory). Atoms have a fixed limit, 1,048,576 by default, and reaching it crashes the whole VM (virtual machine), so a file with enough distinct role values takes the application down. In my test, 1,000 rejected rows added 1,000 atoms. The line also sits outside the `try`, so a row with no role raises instead of returning an error. Fix: `cast/3` converts the role through the schema's allowed values and creates no atoms.

2. Line 53: no welcome email is ever sent. `user[:name]` does not work on a struct (a record with fixed fields), so the background process crashes on every import, and the caller still sees success. `name` is also never set in this module. Fix: use `user.nickname`, which the import always fills in, so the "there" fallback is gone.

3. Lines 15-17: the age cap does nothing. Assigning `age` inside an `if` does not change the `age` outside it, so 150 is stored as 150, and the compiler warns about this. Fix: `min(&1, @max_age)`.

4. Lines 42-43: `rescue _` treats every failure as bad data. If the database is down, each row returns `{:error, :invalid}`, so good rows look rejected and nobody retries them. Fix: the `rescue` is gone. Bad data returns an error and real failures raise.

5. Lines 24-25: two imports of the same email at the same moment can both pass the lookup, because the check and the insert are separate steps. The loser then either stores a duplicate or, with a unique index (a database rule against repeated values), raises and gets reported as `:invalid`. Fix: insert once and let `unique_constraint/2` report the clash.

6. Line 31: `return_id: true` returns a bare id on success but a tuple on failure, so callers cannot handle both with one pattern. Fix: the option is removed. It always returns `{:ok, user}`, and callers read `user.id`.

7. Lines 34 and 37: a duplicate email returns the same `:invalid` as malformed data, so an import report cannot tell them apart. `:insert_failed` also throws away the reason. Fix: return `{:error, changeset}`, which names the field and the reason.

8. Line 49: bare `spawn` runs the email outside any supervisor (a process that tracks and shuts down others). Failures reach no one but the log, and sends in progress are dropped at shutdown. Fix: `Task.Supervisor.start_child/2`. This still does not retry a failed send, so use a job queue such as Oban instead if the project has one.

9. Lines 49 and 54: not fixed, because I cannot see `Mailer`. `welcome_email/1` returns plain text with no recipient, so `Mailer.deliver/1` has no address to send to, and Swoosh, a common mailer library, would reject a string outright. `Mailer` also is not in the `alias` line, so it means top-level `Mailer`, not `Accounts.Mailer`. With bug 2 fixed, this is the next thing that will stop emails.

10. Line 13: the module says it reads JSON (JavaScript Object Notation), but `String.to_integer/1` only takes strings, so a numeric `"age": 30` is rejected as invalid. Fix: `cast/3` accepts both `30` and `"30"`.

11. Line 19: a blank CSV (comma-separated values) nickname arrives as `""`, which `||` treats as present, so the user is stored with an empty nickname. Fix: `cast/3` turns blanks into `nil`, and the email default then applies.

12. Line 21: `is_binary(email)` can never be false, because `String.downcase/1` on line 12 has already raised for anything else. Fix: removed. `validate_required/2` and `cast/3` cover this.

## Cleanups

13. Lines 2, 5, 7 and 48: the first two comments become `@moduledoc` and `@doc`, and the other two only repeat the code, so they are removed. The comment on line 11 stays, because it gives a reason the code cannot show.

14. Lines 10-45: five levels of nesting become one changeset pipeline and one `with`.

15. Lines 53-55: string joining with `<>` and an anonymous function in a pipe become one interpolated string.

16. `:silent` only cancels `:notify`, so one option would do. I kept both, because the gain is only tidiness and removing it means changing callers I cannot see.

## Before merging

The `users` table needs a unique index on `email`. This matters most: the lookup is gone, so without the index duplicates are stored with no error. Ecto expects it to be named `users_email_index`; if it is not, pass `name:` to `unique_constraint/2`.

`User.role` must be an `Ecto.Enum` (a field limited to a fixed list of values). It almost certainly is already, since a plain string field cannot store the atom the old code inserted. If it is a custom type, check that its `cast/1` rejects unknown values.

Add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the application's supervision tree (the processes it starts at boot). Without it, `notify: true` crashes after the user has been inserted.

Callers must change in three ways. Errors are now `{:error, changeset}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`. Passing `return_id:` now raises `ArgumentError`, deliberately, so a stale caller fails at the call rather than later on a tuple it expected to be an id. Database failures now raise instead of returning an error.

If `User` has its own changeset function, build `import_changeset/1` on it, because neither version runs its validations.

## Testing

I ran both versions on SQLite (a file-based database) with a stand-in `User` schema and `Mailer`, and the results match this review for every bug except 8 and 9, which I could not exercise this way. The race in bug 5 was simulated by forcing the lookup to find nothing, not by running real concurrent imports. Nothing was run against the real schema, `Mailer` or production database.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Users under #{@min_age} are rejected. Ages above #{@max_age} are stored as #{@max_age}.
  `nickname` defaults to the email address.

  ## Options

    * `:notify` - send a welcome email after the insert. Defaults to `false`.
    * `:silent` - suppress the welcome email even if `:notify` is set. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false, silent: false)

    with {:ok, user} <- params |> import_changeset() |> Repo.insert() do
      if opts[:notify] && !opts[:silent], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> update_change(:age, &min(&1, @max_age))
    |> default_nickname_to_email()
    |> unique_constraint(:email)
  end

  defp default_nickname_to_email(changeset) do
    case get_change(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_change(changeset, :email))
      _nickname -> changeset
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

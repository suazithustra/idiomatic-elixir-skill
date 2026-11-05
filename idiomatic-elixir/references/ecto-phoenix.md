# Ecto and Phoenix

## Validate input with changesets

Cast and validate external input with `Ecto.Changeset` (`cast/3`, `validate_required/2`, `validate_number/3`, `validate_inclusion/3`) instead of checking fields by hand. A `%User{}` built from the params and passed to `Repo.insert/1` is the pattern to replace: Ecto inserts the struct as given, so nothing is validated and a constraint violation raises. `Repo.update/2` does not accept a struct at all; it raises `ArgumentError`, and only a changeset can carry the changes. Declare database constraints in the changeset (`unique_constraint/3`, and `foreign_key_constraint/3` or `assoc_constraint/3` for a `belongs_to`) so a violation returns `{:error, changeset}` instead of raising. Use `Ecto.Enum` for fields with a fixed set of atom values.

```elixir
# Instead of
Repo.insert(%User{email: params["email"], age: params["age"]})
# write
%User{}
|> User.changeset(params)
|> Repo.insert()
```

Keep fields the code sets, such as `user_id` or `status`, out of the list passed to `cast/3`, so a request cannot set them. Set them on the struct before `cast/3`, or with `put_change/3` and `put_assoc/3` after it. Read a changeset through its functions: `get_field/3` for the current value (changes over data), `changed?/3` or `fetch_change/2` to know whether a field changed (`get_change/3` returns the same `nil` for a field changed to `nil` and a field not changed), and `fetch_field/2` to know whether the value comes from the changes or the data. `changeset[:field]` raises, and `changeset.changes.field` raises when the field did not change.

Changesets also work without a database, through embedded or schemaless changesets, for validating forms and API parameters.

## Let Phoenix turn missing records into 404 responses

In Phoenix controllers, `Repo.get!/2` for a record looked up by an ID from the URL is fine: `phoenix_ecto`, which every generated Phoenix app includes, turns `Ecto.NoResultsError` into a 404 response. When access is restricted, fetch through a query scoped to the current user, `Repo.get!(Blog.user_posts(user), id)`, so a record the user may not see is a 404 as well, instead of fetching by ID and checking the owner afterwards.

## Group writes that must succeed together

Run related writes in one transaction with `Repo.transact/2` (Ecto 3.13+), passing it a function or an `Ecto.Multi`, so a failure rolls back the earlier writes. Only database writes roll back: send emails, messages and other side effects after the transaction commits.

## Load associations up front

Calling `Repo` inside `Enum.map/2` runs one query per element. Load associations with `preload` (in the query or with `Repo.preload/2`), or join, before iterating.

## Keep migrations to schema changes

Schema migrations run automatically on every deploy and every fresh database. A backfill that rewrites existing rows needs review, batching, and a manual run, so Ecto's backfilling guide keeps them apart: schema changes in `priv/repo/migrations`, data changes in `priv/repo/data_migrations`, run by hand with `mix ecto.migrate --migrations-path priv/repo/data_migrations` or, in a release, a `migrate_data` function that calls `Ecto.Migrator`.

A data migration queries the table with raw SQL, or with a small schema defined inside the migration, never with the application's schema modules: those change later, and the migration must keep working against the table as it was when written. On a table that may be large in production, disable the transaction and the migration lock (`@disable_ddl_transaction true`, `@disable_migration_lock true`), update in batches with keyset pagination, and make the migration safe to rerun.

```elixir
# In priv/repo/data_migrations/20261105120000_backfill_orders_currency.exs,
# a module that uses Ecto.Migration:
def up do
  execute "UPDATE orders SET currency = 'EUR' WHERE currency IS NULL"
end

def down, do: :ok
```

## Keep database access in contexts

Controllers, LiveViews, and jobs call context functions (`Accounts.create_user/1`). They do not build queries or call `Repo` directly. Within a context, give each condition that several queries share a small function that takes a query and returns one, so the condition is written once:

```elixir
def list_active_users(org_id) do
  User
  |> for_org(org_id)
  |> active()
  |> order_by(:name)
  |> Repo.all()
end

defp for_org(query, org_id), do: where(query, org_id: ^org_id)

defp active(query), do: where(query, [u], is_nil(u.deactivated_at))
```

Ecto's keyword form (`from u in query, where: ...`) and its pipe form (`where(query, ...)`) build the same query and accept each other's output, so neither is the idiom: choose the one that reads better. The pipe form suits a query assembled from helpers like these; the keyword form suits a standalone query with joins and a select, where every binding is in one place:

```elixir
def list_member_emails(org_id) do
  query =
    from u in User,
      join: m in assoc(u, :memberships),
      where: m.org_id == ^org_id,
      select: {u.name, u.email}

  Repo.all(query)
end
```

When a join and the condition that uses it are in different functions, name the binding where the join is declared, `join: m in assoc(u, :memberships), as: :membership`, and refer to it by name, `where(query, [membership: m], m.role == :admin)`, in either form. Positional bindings refer to sources by order, so they break when someone adds a join earlier.

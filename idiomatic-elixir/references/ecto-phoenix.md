# Ecto and Phoenix

## Validate input with changesets

Cast and validate external input with `Ecto.Changeset` (`cast/3`, `validate_required/2`, `validate_number/3`, `validate_inclusion/3`) instead of checking fields by hand. Declare database constraints in the changeset (`unique_constraint/3`, `foreign_key_constraint/3`) so a violation returns `{:error, changeset}` instead of raising. Use `Ecto.Enum` for fields with a fixed set of atom values.

Changesets also work without a database, through embedded or schemaless changesets, for validating forms and API parameters.

## Let Phoenix turn missing records into 404 responses

In Phoenix controllers, `Repo.get!/2` for a record looked up by an ID from the URL is fine: Phoenix turns `Ecto.NoResultsError` into a 404 response.

## Group writes that must succeed together

Run related writes in one transaction with `Repo.transact/2` (Ecto 3.13+) or `Ecto.Multi`, so a failure rolls back the earlier writes.

## Load associations up front

Calling `Repo` inside `Enum.map/2` runs one query per element. Load associations with `preload` (in the query or with `Repo.preload/2`), or join, before iterating.

## Keep migrations to schema changes

A migration changes tables, columns, and indexes. Backfilling or transforming data in the same migration ties data logic to schema history, makes it hard to test, and breaks when schema modules change later. Put data changes in a separate script, Mix task, or release task, and do not use application schema modules inside migrations.

## Keep database access in contexts

Controllers, LiveViews, and jobs call context functions (`Accounts.create_user/1`). They do not build queries or call `Repo` directly. Within a context, build queries from small composable functions:

```elixir
def list_active_users(org_id) do
  User
  |> where(org_id: ^org_id)
  |> where([u], is_nil(u.deactivated_at))
  |> order_by(:name)
  |> Repo.all()
end
```

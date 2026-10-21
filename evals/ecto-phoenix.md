# Ecto and Phoenix

## Prompt

```text
In a Phoenix 1.8 application with Ecto and PostgreSQL, add blog posts. A post has a title, a body, an optional published_at timestamp, and belongs to a user (the schema MyApp.Accounts.User already exists, with a name field).

We need:

- A MyApp.Blog context with a Post schema, a function that creates a post for a given user from form params, and a function that lists one user's posts newest first for a page that shows each post's title and its author's name.
- A function that publishes a post: it sets published_at to now and also inserts a row in an existing audit_logs table (MyApp.Audit.Log schema) describing the action. Both must happen or neither.
- A migration that adds published_at to the posts table. Existing posts should get published_at set to their inserted_at.
- A controller action that shows one post by its id from the URL.

Write all the code (context, schema, migration, any script, controller) to <output>/blog.ex, with a comment line naming the file each part would live in. Phoenix and Ecto are not installed, so you cannot compile; write it carefully. Reply with just the file path when done.
```

## What to check

- Form params go through a changeset with `cast/3`, `validate_required/2`, and a `foreign_key_constraint/3` or `assoc_constraint/3` for the user.
- `user_id` is not in the `cast/3` list. It is set from the given user, with `put_assoc/3`, `build_assoc/2`, or on the struct.
- The listing query preloads or joins the author; there is no `Repo` call inside `Enum.map/2`.
- Publishing uses `Repo.transact/2` or `Ecto.Multi`, so the audit row and the post update succeed or fail together.
- The migration only adds the column. The backfill of `published_at` is a separate script, Mix task, or release task, and it does not use `MyApp.Blog.Post`.
- The controller calls context functions; it does not build queries or call `Repo` itself. `Repo.get!/2` inside the context for the URL id is fine.
- Error reasons are atoms, tuples, or changesets, not strings.
- No comments that restate the code; documentation is in `@moduledoc` and `@doc`.
- Expected reads: `ecto-phoenix.md`.

## Seen so far

- Not yet run.

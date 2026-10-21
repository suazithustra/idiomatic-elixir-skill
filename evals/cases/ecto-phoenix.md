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
- The controller calls context functions; it does not build queries or call `Repo` itself.
- The show action lets `Repo.get!/2` raise for a missing id, which Phoenix turns into a 404, instead of matching `nil` and rendering a 404 by hand.
- Error reasons are atoms, tuples, or changesets, not strings.
- No comments that restate the code; documentation is in `@moduledoc` and `@doc`.
- Expected reads: `ecto-phoenix.md`.

## Seen so far

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Wrote a correct context with a constrained changeset, joined preload, Multi transaction and get!-based show action, but backfilled published_at with an UPDATE inside the migration, breaking only Keep migrations to schema changes.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Wrote a correct changeset, preload, Multi transaction and get!-based show action, but backfilled published_at inside the migration, breaking Keep migrations to schema changes, and also pipes a single step and returns Multi's 4-tuple error from publish_post/1.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Used a transaction, preload and get!-based show action correctly, but left the user constraint out of the changeset and backfilled published_at inside the migration, breaking Validate input with changesets and Keep migrations to schema changes.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Wrote a correct changeset with foreign_key_constraint, joined preload, Multi transaction and get!-based show action, but backfilled published_at inside the migration, breaking Keep migrations to schema changes, and publish_post/1 returns two different error shapes.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Wrote a correct changeset, joined preload, Multi transaction and get!-based show action, but backfilled published_at inside the migration, breaking Keep migrations to schema changes, plus two single-step pipes and an undocumented change_post/2.
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Wrote a constrained changeset, preloaded listing, Repo.transact/2 publish, column-only migration with a separate release-task backfill that avoids the schema module, and a get!-based show action, breaking no listed rule; read SKILL.md and ecto-phoenix.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Wrote a constrained changeset, preloaded listing, Repo.transact/2 publish, column-only migration and get!-based show action, breaking no listed rule, but its separate backfill script uses MyApp.Blog.Post and calls Repo.update_all/1 (line 138), which does not exist (update_all takes the updates list as a second argument); read SKILL.md and ecto-phoenix.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Used Repo.transact/2, a preloaded listing, a column-only migration and a get!-based show action, but left the user constraint out of the changeset, breaking Validate input with changesets; its separate backfill script uses MyApp.Blog.Post, it pipes a single step, and MyApp.Blog has no @moduledoc; read SKILL.md and ecto-phoenix.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Wrote a constrained changeset, preloaded listing, Repo.transact/2 publish with an :already_published guard clause, column-only migration with a separate table-name backfill script, and a get!-based show action, breaking no listed rule; read SKILL.md and ecto-phoenix.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Wrote a constrained changeset, preloaded listing, Ecto.Multi publish that returns a single 2-tuple error shape, column-only migration with a separate table-name backfill script, and a get!-based show action, breaking no listed rule; read SKILL.md and ecto-phoenix.md.

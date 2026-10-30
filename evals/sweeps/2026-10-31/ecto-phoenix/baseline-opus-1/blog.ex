# Blog posts for MyApp. Each part below starts with a comment naming its file.
#
# Assumptions, because the existing code was not available to read:
#
# - The posts table already exists with a bigint id, title, body, user_id,
#   inserted_at and updated_at. The migrations below only add published_at.
# - MyApp.Audit.Log has the fields action, user_id, entity_type and entity_id.
#   If it does not, the compiler rejects audit_log/2 in MyApp.Blog, which is
#   the only function to change.
# - Authentication comes from Phoenix 1.8 phx.gen.auth, which sets
#   conn.assigns.current_scope. Without it, every visitor counts as signed out.
# - posts.user_id has an index. If it does not, list_user_posts/1 reads the
#   whole table, so add `create index(:posts, [:user_id], concurrently: true)`.
#
# Decisions beyond the request:
#
# - A NULL published_at means draft, so the show action returns 404 for a draft
#   unless the viewer wrote it.
# - publish_post/2 takes the acting user so the audit row records who published.
# - Publishing a post twice returns {:error, :already_published} and writes no
#   second audit row.
# - The show action needs a view, so MyAppWeb.PostHTML is included.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for form params. Does not cast `user_id` or `published_at`, so a
  form cannot assign a post to another user or publish it without an audit row.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:user_id)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists all of `user`'s posts, drafts included, newest first, with each post's
  `user` loaded. A page open to other visitors should leave the drafts out.
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]
    )
  end

  @doc """
  Gets a post that `viewer` may read, with its `user` loaded. `viewer` is a
  `User`, or `nil` for a signed-out visitor.

  Raises `Ecto.NoResultsError`, which Phoenix turns into a 404, if the post does
  not exist or is a draft written by someone else.
  """
  def get_visible_post!(id, viewer) do
    Post
    |> visible_to(viewer)
    |> preload(:user)
    |> Repo.get!(id)
  end

  defp visible_to(query, %User{id: user_id}) do
    where(query, [p], not is_nil(p.published_at) or p.user_id == ^user_id)
  end

  defp visible_to(query, nil) do
    where(query, [p], not is_nil(p.published_at))
  end

  @doc """
  Publishes a post and records it in the audit log. Both writes happen in one
  transaction, so if either fails, neither is kept.

  Returns `{:ok, post}`, `{:error, :already_published}`, or
  `{:error, changeset}` if the audit row cannot be inserted.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:post, fn repo, _changes -> mark_published(repo, post, now) end)
    |> Multi.insert(:audit_log, fn %{post: published} -> audit_log(published, actor) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # The UPDATE itself checks published_at, so when two requests race, only one
  # changes the row and only one audit row is written.
  defp mark_published(repo, %Post{id: id}, now) do
    query = from p in Post, where: p.id == ^id and is_nil(p.published_at), select: p

    case repo.update_all(query, set: [published_at: now, updated_at: now]) do
      {1, [published]} -> {:ok, published}
      {0, []} -> {:error, :already_published}
    end
  end

  defp audit_log(%Post{} = post, %User{} = actor) do
    %Log{action: "post.published", user_id: actor.id, entity_type: "post", entity_id: post.id}
  end
end

# priv/repo/migrations/20261031120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # The backfill is a separate migration. A migration runs in one transaction,
  # so an UPDATE here would keep the table locked by this ALTER, blocking all
  # reads and writes on posts until every row was done.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/migrations/20261031120100_backfill_posts_published_at.exs
defmodule MyApp.Repo.Migrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  # Each batch commits on its own, so rows stay locked only briefly and the app
  # keeps working during the backfill.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1_000
  @pause_ms 100

  # Uses SQL rather than MyApp.Blog.Post so that later schema changes cannot
  # break this migration.
  #
  # Run this before the new code starts, in the same `mix ecto.migrate` as the
  # migration above. Once the new code is live, NULL means draft, and a rerun
  # would publish any drafts below max(id). A post the old code creates after
  # max(id) is read stays NULL and shows up as a draft of its author.
  def up do
    %{rows: [[max_id]]} = repo().query!("SELECT coalesce(max(id), 0) FROM posts")
    backfill(0, max_id)
  end

  # Rolling back the migration above drops the column and the values with it.
  def down, do: :ok

  defp backfill(last_id, max_id) when last_id >= max_id, do: :ok

  defp backfill(last_id, max_id) do
    next_id = min(last_id + @batch_size, max_id)

    repo().query!(
      """
      UPDATE posts
      SET published_at = inserted_at
      WHERE id > $1 AND id <= $2 AND published_at IS NULL
      """,
      [last_id, next_id]
    )

    Process.sleep(@pause_ms)
    backfill(next_id, max_id)
  end
end

# lib/my_app_web/router.ex (add inside the existing scope that pipes through :browser)
#
#   get "/posts/:id", PostController, :show

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_visible_post!(id, current_user(conn))
    render(conn, :show, post: post)
  end

  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: user} -> user
      nil -> nil
    end
  end
end

# lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <article>
        <h1>{@post.title}</h1>
        <p>By {@post.user.name}</p>
        <p>{@post.body}</p>
      </article>
    </Layouts.app>
    """
  end
end

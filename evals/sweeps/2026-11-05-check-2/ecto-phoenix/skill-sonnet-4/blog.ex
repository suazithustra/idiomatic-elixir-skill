# Assumptions: the posts table and users table already exist (posts has
# title, body, user_id and timestamps), and MyApp.Audit.Log has an `action`
# string and a `description` string and a `changeset/2` that casts both.
# Adjust the Log attrs in publish_post/1 to the real fields.

# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  A post with no `published_at` is a draft.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast, so a request cannot set them.
  Set `user_id` on the struct and publish through `MyApp.Blog.publish_post/1`.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Builds a changeset that marks the post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and the actions on them.
  """

  import Ecto.Query, only: [from: 2, order_by: 2, where: 3]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a draft post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> for_user(user)
    |> newest_first()
    |> with_author()
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author loaded.

  Raises `Ecto.NoResultsError` when there is no such post, which Phoenix
  turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> with_author()
    |> Repo.get!(id)
  end

  @doc """
  Publishes a draft: sets `published_at` to now and writes an audit log row.

  Both writes happen in one transaction, so both or neither are saved.
  Returns `{:ok, post}`, `{:error, :already_published}` or
  `{:error, changeset}`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post),
           {:ok, _log} <- log_published(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp update_published_at(post) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  defp log_published(post) do
    attrs = %{
      action: "post.published",
      description: "Post #{post.id} published by user #{post.user_id}"
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end

  defp for_user(query, user), do: where(query, [post], post.user_id == ^user.id)

  # id breaks ties between posts inserted in the same second.
  defp newest_first(query), do: order_by(query, desc: :inserted_at, desc: :id)

  defp with_author(query) do
    from(post in query,
      join: author in assoc(post, :user),
      preload: [user: author]
    )
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/data_migrations/20261105120100_backfill_posts_published_at.exs
#
# Run by hand after the schema migration:
#   mix ecto.migrate --migrations-path priv/repo/data_migrations
#
# Existing posts become published at their inserted_at. Run it before the
# app version that creates drafts is live, otherwise new drafts (which also
# have a NULL published_at) are published too. Safe to rerun: it only touches
# rows whose published_at is still NULL.
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.DataMigrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1_000

  @batch_sql """
  WITH batch AS (
    SELECT id FROM posts
    WHERE id > $1 AND published_at IS NULL
    ORDER BY id
    LIMIT $2
  ),
  updated AS (
    UPDATE posts
    SET published_at = posts.inserted_at
    FROM batch
    WHERE posts.id = batch.id
    RETURNING posts.id
  )
  SELECT max(id) FROM updated
  """

  def up do
    backfill_after(0)
  end

  def down, do: :ok

  defp backfill_after(last_id) do
    %{rows: [[max_id]]} = repo().query!(@batch_sql, [last_id, @batch_size])

    case max_id do
      nil ->
        :ok

      max_id ->
        backfill_after(max_id)
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (inside the browser scope)
# ---------------------------------------------------------------------------
# get "/posts/:id", PostController, :show

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_html.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_html/show.html.heex
# ---------------------------------------------------------------------------
# <h1>{@post.title}</h1>
# <p>By {@post.user.name}</p>
# <div>{@post.body}</div>

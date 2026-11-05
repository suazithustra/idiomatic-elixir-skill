# Assumptions: Ecto 3.13+ (Repo.transact/2), a `posts` table with integer ids that
# already holds title, body, user_id and timestamps, and an existing
# MyApp.Audit.Log schema. The audit fields used below (:action, :description,
# :user_id) and Log.changeset/2 are guesses; match them to the real schema.

# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post with no `published_at` is a draft.
  """

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
  Casts and validates form params. `user_id` and `published_at` are not cast,
  so a request cannot set them.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Marks the post as published at `published_at`.
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
  Blog posts and their publication.
  """

  import Ecto.Query, only: [order_by: 3, preload: 3, where: 3]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> for_user(user)
    |> newest_first()
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author loaded.

  Raises `Ecto.NoResultsError` when there is none, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and writes an audit log row in one transaction, so either
  both happen or neither does.

  Returns `{:error, :already_published}` for a post that has a `published_at`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp for_user(query, user), do: where(query, user_id: ^user.id)

  defp newest_first(query), do: order_by(query, [post], desc: post.inserted_at, desc: post.id)

  defp set_published_at(post) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      description: "Post #{post.id} published",
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
# Schema change only. The backfill is a separate data migration below.
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
# Run by hand after the migration above, and before the app starts creating
# drafts (otherwise a new draft would be marked as published):
#   mix ecto.migrate --migrations-path priv/repo/data_migrations
# Raw SQL, batched by id, and safe to rerun: rows that already have a
# published_at are skipped.
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.DataMigrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1_000

  @backfill_batch """
  WITH batch AS (
    SELECT id
    FROM posts
    WHERE id > $1 AND published_at IS NULL
    ORDER BY id
    LIMIT $2
  )
  UPDATE posts
  SET published_at = posts.inserted_at
  FROM batch
  WHERE posts.id = batch.id
  RETURNING posts.id
  """

  def up do
    backfill_after(0)
  end

  def down, do: :ok

  defp backfill_after(last_id) do
    %{rows: rows} = repo().query!(@backfill_batch, [last_id, @batch_size], log: false)

    case rows do
      [] ->
        :ok

      _rows ->
        backfill_after(rows |> List.flatten() |> Enum.max())
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# Route: get "/posts/:id", PostController, :show
# The :show template (post_html/show.html.heex) renders @post.title,
# @post.body and @post.user.name.
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

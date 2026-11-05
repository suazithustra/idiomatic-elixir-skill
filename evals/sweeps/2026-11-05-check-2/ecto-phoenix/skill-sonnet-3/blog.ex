# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `user_id` and `published_at` are set by `MyApp.Blog`, so `changeset/2` does
  not cast them from form params.
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

  @doc false
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publication.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params (`"title"` and `"body"`).

  Returns `{:error, changeset}` when the params are invalid.
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
    |> for_user(user.id)
    |> newest_first()
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post with its author. Raises `Ecto.NoResultsError` when it does not
  exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.

  Both writes happen in one transaction, so either both are saved or neither.
  Returns `{:error, :already_published}` for a post that has a `published_at`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_publication(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp for_user(query, user_id), do: where(query, user_id: ^user_id)

  defp newest_first(query), do: order_by(query, desc: :inserted_at, desc: :id)

  defp set_published_at(post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has `action`, `resource_type` and `resource_id`
  # fields and a `changeset/2`; adjust the keys to the real schema.
  defp log_publication(post) do
    params = %{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id
    }

    %Log{}
    |> Log.changeset(params)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex  (inside the existing scope "/" with the browser pipeline)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
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
# priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
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
# priv/repo/data_migrations/20261105120100_backfill_posts_published_at.exs
# Run by hand right after the schema migration, before the new code creates
# drafts (a draft has a nil published_at and would be backfilled too):
#     mix ecto.migrate --migrations-path priv/repo/data_migrations
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.DataMigrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1_000

  def up, do: backfill(0)

  def down, do: :ok

  # Keyset pagination on id. Rows that already have a published_at are
  # skipped, so the migration is safe to rerun.
  defp backfill(last_id) do
    result = repo().query!(batch_sql(), [last_id, @batch_size])

    case result.rows do
      [] ->
        :ok

      rows ->
        backfill(rows |> List.flatten() |> Enum.max())
    end
  end

  defp batch_sql do
    """
    WITH batch AS (
      SELECT id FROM posts
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
  end
end

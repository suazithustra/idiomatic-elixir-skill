# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is `nil` until the post is published.
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
  Changeset for form params. `user_id` and `published_at` are set by the
  code, so they are not cast.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Changeset that marks a post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publication.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with `:user` loaded for the
  author's name.
  """
  def list_user_posts(%User{} = user) do
    query =
      from(post in Post,
        join: author in assoc(post, :user),
        where: post.user_id == ^user.id,
        order_by: [desc: post.inserted_at, desc: post.id],
        preload: [user: author]
      )

    Repo.all(query)
  end

  @doc """
  Gets a post by id, with `:user` loaded. Raises `Ecto.NoResultsError` when
  there is none, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post: sets `published_at` to now and writes an audit log row.
  Both writes happen or neither does.

  Returns `{:error, :already_published}` for a post that is already published.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp update_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has `action`, `subject_id` and `user_id` fields
  # and a `changeset/2` that casts them.
  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      subject_id: post.id,
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/data_migrations/20261105120100_backfill_posts_published_at.exs
# Run by hand once, after the migration above and before any draft exists:
#   mix ecto.migrate --migrations-path priv/repo/data_migrations
# Rerunning it also publishes drafts created since, so do not rerun it later.
defmodule MyApp.Repo.DataMigrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1_000

  # Raw SQL, not MyApp.Blog.Post, so the migration keeps working when the
  # schema module changes. Keyset pagination on id.
  @update_batch """
  UPDATE posts
  SET published_at = inserted_at
  WHERE id IN (
    SELECT id
    FROM posts
    WHERE id > $1 AND published_at IS NULL
    ORDER BY id
    LIMIT $2
  )
  RETURNING id
  """

  def up do
    backfill(0)
  end

  def down, do: :ok

  defp backfill(last_id) do
    %{rows: rows} = repo().query!(@update_batch, [last_id, @batch_size])

    case rows do
      [] ->
        :ok

      _rows ->
        backfill(rows |> Enum.map(fn [id] -> id end) |> Enum.max())
    end
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/router.ex (inside the browser scope)
#   get "/posts/:id", PostController, :show

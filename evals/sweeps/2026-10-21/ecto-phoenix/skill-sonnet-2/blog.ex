# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is `nil` until `MyApp.Blog.publish_post/1` runs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.User

  @type t :: %__MODULE__{}

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast: the context sets them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  @spec create_post(User.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists one user's posts, newest first, with each post's author loaded.
  """
  @spec list_user_posts(User.t()) :: [Post.t()]
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([post], desc: post.inserted_at, desc: post.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post by id, with its author loaded.

  Raises `Ecto.NoResultsError` if there is none, which Phoenix renders as a 404.
  """
  @spec get_post!(term()) :: Post.t()
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.

  Both writes run in one transaction: if either fails, neither is kept.
  """
  @spec publish_post(Post.t()) ::
          {:ok, Post.t()} | {:error, :already_published} | {:error, Ecto.Changeset.t()}
  def publish_post(%Post{published_at: nil} = post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    Multi.new()
    |> Multi.update(:post, Ecto.Changeset.change(post, published_at: published_at))
    |> Multi.insert(:log, fn %{post: published} -> publish_log(published) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  # Assumes MyApp.Audit.Log has `action` and `description` string fields and a
  # `changeset/2` that casts them. Adjust to the real schema.
  defp publish_log(%Post{} = post) do
    Log.changeset(%Log{}, %{
      action: "post.published",
      description: "Post #{post.id} published by user #{post.user_id}"
    })
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
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
# File: priv/repo/backfill_published_at.exs
#
# Run once, right after the migration: mix run priv/repo/backfill_published_at.exs
# It marks every post that has no published_at as published at its inserted_at,
# so run it before any new drafts are created. It queries the "posts" table
# by name, not through MyApp.Blog.Post, so later schema changes cannot break it.
# ---------------------------------------------------------------------------
import Ecto.Query

{count, _rows} =
  MyApp.Repo.update_all(
    from(post in "posts",
      where: is_nil(post.published_at),
      update: [set: [published_at: post.inserted_at]]
    ),
    []
  )

IO.puts("Backfilled published_at on #{count} posts")

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
# File: lib/my_app_web/router.ex (add inside the browser scope)
#
#   get "/posts/:id", PostController, :show
# ---------------------------------------------------------------------------

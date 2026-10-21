# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.
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
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast, so a request cannot set them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Builds a changeset that marks the post as published at `published_at`.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias MyApp.Audit.Log
  alias MyApp.Accounts.User
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
  Lists the posts of `user`, newest first, with each author loaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([post], desc: post.inserted_at, desc: post.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author loaded. Raises `Ecto.NoResultsError` if
  it does not exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, published_at))
    |> Multi.insert(:log, fn %{post: published_post} ->
      # The field names of MyApp.Audit.Log are assumed; adjust to the real schema.
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "post",
        resource_id: published_post.id,
        user_id: published_post.user_id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published_post}} -> {:ok, published_post}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
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
# priv/repo/backfill_post_published_at.exs
# Run once after the migration: mix run priv/repo/backfill_post_published_at.exs
# It is a separate script so the migration holds only the schema change.
# ---------------------------------------------------------------------------
import Ecto.Query

{count, _} =
  MyApp.Repo.update_all(
    from(post in "posts",
      where: is_nil(post.published_at),
      update: [set: [published_at: post.inserted_at]]
    ),
    []
  )

IO.puts("Set published_at on #{count} existing posts")

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

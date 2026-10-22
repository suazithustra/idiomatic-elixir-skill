# lib/my_app/blog/post.ex
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
  Changeset for form params. `user_id` and `published_at` are set by the
  code, so they are not cast.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset that marks the post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their authors loaded.
  """
  def list_posts(%User{id: user_id}) do
    query =
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Gets a post with its author. Raises `Ecto.NoResultsError` when there is
  none, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log. Both writes
  happen or neither does.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    # Assumes MyApp.Audit.Log casts :action and :description.
    log_params = %{
      action: "post.published",
      description: "Post #{post.id} (#{post.title}) published by user #{post.user_id}"
    }

    multi =
      Multi.new()
      |> Multi.update(:post, Post.publish_changeset(post, published_at))
      |> Multi.insert(:audit_log, Log.changeset(%Log{}, log_params))

    case Repo.transaction(multi) do
      {:ok, %{post: published_post}} -> {:ok, published_post}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end
end

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/backfill_published_at.exs
# Kept out of the migration so schema history holds no data logic. It uses the
# table name, not MyApp.Blog.Post, so later schema changes cannot break it.
import Ecto.Query, only: [from: 2]

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(backfill, [])

IO.puts("Set published_at on #{count} existing posts")

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

# lib/my_app_web/router.ex (inside the browser scope)
#
#     get "/posts/:id", PostController, :show

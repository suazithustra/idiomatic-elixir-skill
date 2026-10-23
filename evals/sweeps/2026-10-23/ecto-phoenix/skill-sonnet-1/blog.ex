# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261023000000_add_published_at_to_posts.exs
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
# File: priv/repo/scripts/backfill_post_published_at.exs
#
# Run once, right after the migration: mix run priv/repo/scripts/backfill_post_published_at.exs
# It marks every post without a published_at as published at its inserted_at,
# so run it before anyone saves a new draft. It reads the "posts" table by
# name and does not use MyApp.Blog.Post, so later schema changes cannot break it.
# ---------------------------------------------------------------------------
import Ecto.Query, only: [from: 2]

unpublished_posts =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(unpublished_posts, [])

IO.puts("Set published_at on #{count} posts")

# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
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

    timestamps()
  end

  @doc """
  Casts and validates form params for a new post.

  `user_id` and `published_at` are not cast: the context sets them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Builds the change that marks a post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
#
# Assumes MyApp.Audit.Log has a changeset/2 that casts :action and
# :description. Adjust the attrs in audit_log_attrs/1 to the real fields.
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [from: 2]

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
  Lists the posts of `user`, newest first, with each post's author loaded.
  """
  def list_posts(%User{} = user) do
    query =
      from p in Post,
        join: author in assoc(p, :user),
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: author]

    Repo.all(query)
  end

  @doc """
  Gets a post by id with its author loaded.

  Raises `Ecto.NoResultsError` if there is no such post, which Phoenix
  renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and records the action in the audit log.

  Both writes happen in one transaction, so a failure in either leaves
  the post unpublished and writes no log row.
  """
  def publish_post(%Post{published_at: nil} = post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.transact(fn ->
      with {:ok, published_post} <- update_published_at(post, published_at),
           {:ok, _log} <- insert_audit_log(published_post) do
        {:ok, published_post}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp update_published_at(post, published_at) do
    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  defp insert_audit_log(post) do
    %Log{}
    |> Log.changeset(audit_log_attrs(post))
    |> Repo.insert()
  end

  defp audit_log_attrs(post) do
    %{
      action: "post_published",
      description: "Post #{post.id} published by user #{post.user_id}"
    }
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex (inside the existing browser scope)
#
#   get "/posts/:id", PostController, :show
# ---------------------------------------------------------------------------

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

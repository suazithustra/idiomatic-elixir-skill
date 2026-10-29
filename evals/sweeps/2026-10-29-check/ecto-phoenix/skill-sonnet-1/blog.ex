# ---------------------------------------------------------------------------
# priv/repo/migrations/20261029000000_add_published_at_to_posts.exs
#
# Assumes the posts table already exists with title, body, user_id and
# timestamps. The migration only changes the schema; the backfill is in
# priv/repo/backfill_published_at.exs.
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
# priv/repo/backfill_published_at.exs
#
# Run once after the migration: mix run priv/repo/backfill_published_at.exs
# Uses the table name instead of MyApp.Blog.Post so it keeps working when the
# schema module changes. Safe to run twice: it skips posts already set.
# ---------------------------------------------------------------------------
import Ecto.Query, only: [from: 2]

alias MyApp.Repo

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = Repo.update_all(backfill, [])

IO.puts("Set published_at on #{count} existing posts")

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is `nil` until the post is
  published with `MyApp.Blog.publish_post/1`.
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
  Casts and validates form params. `user_id` and `published_at` are not
  cast, so a request cannot set them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
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
# lib/my_app/blog.ex
#
# Assumes MyApp.Audit.Log has an `action` and a `description` field and a
# `changeset/2` function; adjust the attrs in insert_audit_log/1 to match.
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

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
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post with its author. Raises `Ecto.NoResultsError` when there is
  none, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.

  Both writes happen in one transaction: if the audit row fails, the post
  stays unpublished.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_audit_log(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp insert_audit_log(post) do
    attrs = %{action: "post.published", description: "Published post #{post.id}"}

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

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

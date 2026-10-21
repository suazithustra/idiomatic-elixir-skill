# Assumptions (not compiled here; Phoenix and Ecto are not installed):
# - The posts table already exists with title, body, user_id (references users),
#   and inserted_at/updated_at timestamps.
# - MyApp.Audit.Log has changeset/2 and fields action, resource_type,
#   resource_id, and details. Adjust the attrs in MyApp.Blog.publish_post/1
#   if the real schema differs.
# - MyApp.Accounts.User already has a name field. It needs no changes.

# ============================================================
# lib/my_app/blog/post.ex
# ============================================================
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# ============================================================
# lib/my_app/blog.ex
# ============================================================
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, fetching, and publishing.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns all posts by `user`, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author. Raises Ecto.NoResultsError if missing.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets published_at to now and inserts an audit log row in one transaction.
  Both succeed or neither is saved.

  Returns {:ok, %{post: post, audit_log: log}} on success, or
  {:error, failed_step, changeset, changes_so_far} on failure.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Changeset.change(post, published_at: now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "post",
        resource_id: published.id,
        details: "Published post #{published.id} at #{DateTime.to_iso8601(now)}"
      })
    end)
    |> Repo.transaction()
  end
end

# ============================================================
# priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
# ============================================================
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts were treated as published when they were created.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ============================================================
# lib/my_app_web/controllers/post_controller.ex
# Route to add in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
# Template to add: lib/my_app_web/controllers/post_html/show.html.heex
# (rendered by MyAppWeb.PostHTML.show/1 via Phoenix 1.8's :html format).
# ============================================================
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

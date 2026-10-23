# ---------------------------------------------------------------------------
# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # The alter above is queued; flush so the column exists before the backfill.
    flush()

    # Plain SQL rather than the Post schema, so this migration keeps working
    # no matter how the schema module changes later.
    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
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

  @doc """
  Changeset for user-editable fields. `user_id` and `published_at` are
  deliberately not cast: the owner is set by the context, and publishing
  goes through `MyApp.Blog.publish_post/1`.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post

  @doc """
  Lists the given user's posts, newest first, with `:user` preloaded so the
  page can render each post's author name without an N+1.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a single post with its author preloaded.

  Raises `Ecto.NoResultsError` (rendered as a 404 by Phoenix) if not found.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a changeset for tracking post changes (for forms).
  """
  def change_post(%Post{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  @doc """
  Publishes a post: sets `published_at` to now and records an audit log
  entry, atomically. Returns `{:ok, post}` or `{:error, changeset}` from
  whichever step failed; on error nothing is written.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: post} ->
      # Field names assume the existing MyApp.Audit.Log schema; adjust to match.
      Log.changeset(%Log{}, %{
        action: "post.published",
        user_id: post.user_id,
        resource_type: "post",
        resource_id: post.id,
        metadata: %{published_at: post.published_at}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Route: get "/posts/:id", PostController, :show
  def show(conn, %{"id" => id}) do
    # Missing id -> Ecto.NoResultsError, malformed id -> Ecto.Query.CastError;
    # Phoenix turns both into 404/400 responses.
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_html.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <article>
      <h1>{@post.title}</h1>
      <p>by {@post.user.name}</p>
      <p :if={@post.published_at}>Published {@post.published_at}</p>
      <div>{@post.body}</div>
    </article>
    """
  end
end

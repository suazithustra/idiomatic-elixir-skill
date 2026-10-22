# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts count as already published at the time they were created.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
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

  # published_at and user_id are deliberately not castable from form params:
  # publishing goes through Blog.publish_post/1 and the owner is set by the context.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, warn: false

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
  Lists a user's posts, newest first, with each post's `:user` preloaded
  (in the same query) so the page can show the author's name.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> join(:inner, [p], u in assoc(p, :user))
    |> preload([_p, u], user: u)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> Repo.all()
  end

  @doc """
  Gets a single post with its author. Raises `Ecto.NoResultsError` if not found.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and records the action in the audit log, atomically.

  Assumes `MyApp.Audit.Log` has a `changeset/2` that casts `:action`,
  `:user_id`, `:resource_type`, `:resource_id` and `:metadata`; adjust to
  the real schema.
  """
  def publish_post(%Post{published_at: nil} = post) do
    published_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, published_at))
    |> Multi.insert(:audit_log, fn %{post: post} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        user_id: post.user_id,
        resource_type: "post",
        resource_id: post.id,
        metadata: %{title: post.title, published_at: DateTime.to_iso8601(published_at)}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def publish_post(%Post{}), do: {:error, :already_published}
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (inside the browser scope)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # A missing post raises Ecto.NoResultsError (rendered as 404) and a
  # malformed id raises Ecto.Query.CastError (rendered as 400) via phoenix_ecto.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

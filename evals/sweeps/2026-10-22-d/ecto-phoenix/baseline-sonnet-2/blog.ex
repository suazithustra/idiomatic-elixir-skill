# Assumptions: the posts table already exists (title, body, user_id, timestamps)
# and MyApp.Audit.Log has `action`, `description`, and `user_id` fields.

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts count as published at the time they were inserted.
    execute "UPDATE posts SET published_at = inserted_at"
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

  @doc "Changeset for form params. user_id is deliberately not castable."
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published_at])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc "The Blog context."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Audit.Log
  alias MyApp.Accounts.User
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params."
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Returns a changeset for tracking post changes in forms."
  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Lists the user's posts, newest first, with the author preloaded
  (a single joined query, no N+1 when rendering author names).
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        join: u in assoc(p, :user),
        preload: [user: u]
    )
  end

  @doc "Gets a single post with its author. Raises `Ecto.NoResultsError` if not found."
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and records an audit log entry atomically.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: post} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        description: "Published post #{post.id} (#{post.title})",
        user_id: post.user_id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Ecto.NoResultsError raised by get_post!/1 is rendered as a 404 by Phoenix.
  def show(conn, %{"id" => id}) do
    render(conn, :show, post: Blog.get_post!(id))
  end
end

# In lib/my_app_web/router.ex:
#   get "/posts/:id", PostController, :show

# Assumptions: a posts table already exists with title, body, user_id and
# timestamps (inserted_at/updated_at as :utc_datetime). MyApp.Audit.Log is
# assumed to have the fields action (string), user_id and metadata (map);
# adjust the %Log{} in publish_post/1 to the real schema.

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261023000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts count as published at the time they were created.
    # Rollback: the column is dropped, so the backfill needs no reverse.
    execute(
      "UPDATE posts SET published_at = inserted_at",
      ""
    )
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

  # Form changeset. user_id and published_at are deliberately not cast, so
  # form params cannot set the author or publish a post.
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
  @moduledoc "Blog posts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params."
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Lists a user's posts, newest first, with the author loaded in the same
  query (no per-post lookup for the author's name).
  """
  def list_user_posts(%User{} = user) do
    Repo.all(
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]
    )
  end

  @doc """
  Gets a post by id with its author. Raises Ecto.NoResultsError when missing,
  which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets published_at to now and writes an audit log row, in one transaction.
  Returns {:ok, post} or {:error, changeset}. A post that is already
  published returns {:error, changeset} with an error on :published_at.
  """
  def publish_post(%Post{published_at: nil} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      %Log{
        action: "post.published",
        user_id: published.user_id,
        metadata: %{post_id: published.id, title: published.title}
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def publish_post(%Post{} = post) do
    changeset =
      post
      |> Post.changeset(%{})
      |> Ecto.Changeset.add_error(:published_at, "is already published")

    {:error, %{changeset | action: :update}}
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# (route in lib/my_app_web/router.ex: `get "/posts/:id", PostController, :show`)
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
# File: lib/my_app_web/controllers/post_html.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_html/show.html.heex
# (template content, shown here as a comment)
# ---------------------------------------------------------------------------
#   <h1>{@post.title}</h1>
#   <p>By {@post.user.name}</p>
#   <div>{@post.body}</div>

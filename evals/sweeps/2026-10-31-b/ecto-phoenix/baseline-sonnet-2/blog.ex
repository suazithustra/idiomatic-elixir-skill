# Assumptions (not visible to me, adjust if wrong):
#   * A `posts` table already exists with title, body, user_id and timestamps().
#   * MyApp.Audit.Log has string fields `action` and `description`. If its
#     fields differ, change the struct in Blog.publish_post/1.

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts count as published at the time they were created.
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

    timestamps()
  end

  # Used for form params. user_id and published_at are not cast, so a form
  # cannot choose the author or publish a post directly.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:user_id)
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

  @doc """
  Lists one user's posts, newest first, with the author loaded in the same
  query (no per-post lookup for the author's name).
  """
  def list_user_posts(%User{id: user_id}) do
    from(p in Post,
      join: u in assoc(p, :user),
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [user: u]
    )
    |> Repo.all()
  end

  @doc "Gets a post and its author by id. Raises if not found."
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row, in one transaction.
  If either step fails, neither is saved.
  """
  def publish_post(%Post{published_at: %DateTime{}}), do: {:error, :already_published}

  def publish_post(%Post{} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Ecto.Changeset.change(post, published_at: now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      %Log{
        action: "post.published",
        description: "Post #{published.id} (#{published.title}) published at #{DateTime.to_iso8601(now)}"
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Route: get "/posts/:id", PostController, :show
  # A missing id raises Ecto.NoResultsError, which Phoenix renders as a 404.
  # Note: this shows unpublished posts too; add a check if drafts must be private.
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
# ---------------------------------------------------------------------------
# <h1>{@post.title}</h1>
# <p>By {@post.user.name}</p>
# <div>{@post.body}</div>

# Assumptions: a `posts` table already exists with title, body, user_id (references users)
# and timestamps. MyApp.Audit.Log has `action` (string) and `description` (string) fields;
# adjust the Log attrs in publish_post/1 to match the real schema.

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # The column must exist before the backfill runs.
    flush()

    # Existing posts count as published at the time they were created.
    execute("UPDATE posts SET published_at = inserted_at")
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

  # published_at and user_id are deliberately not cast: form params must not be
  # able to publish a post or assign it to another user.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc "Blog posts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Audit
  alias MyApp.Accounts.User
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params (title and body only)."
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Changeset for rendering a new-post form."
  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Lists a user's posts, newest first, with the author preloaded in the same
  query (one SQL statement, no per-post author lookup).
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

  @doc "Fetches a post with its author. Raises Ecto.NoResultsError (404) if missing."
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and writes an audit log row in one transaction.

  The update only matches rows that are still unpublished, so two concurrent
  calls cannot both succeed and the original published_at is never overwritten.

  Returns `{:ok, post}` or `{:error, :already_published}` or `{:error, changeset}`.
  """
  def publish_post(%Post{id: post_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:post, fn repo, _changes ->
      query = from(p in Post, where: p.id == ^post_id and is_nil(p.published_at), select: p)

      case repo.update_all(query, set: [published_at: now, updated_at: now]) do
        {1, [post]} -> {:ok, post}
        {0, _} -> {:error, :already_published}
      end
    end)
    |> Multi.insert(:audit_log, fn %{post: post} ->
      Audit.Log.changeset(%Audit.Log{}, %{
        action: "post.published",
        description: "Published post #{post.id} (#{post.title}) at #{DateTime.to_iso8601(now)}"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, :post, reason, _changes} -> {:error, reason}
      {:error, :audit_log, changeset, _changes} -> {:error, changeset}
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # The id comes from the URL as a string. Ecto casts it; a non-numeric id raises
  # Ecto.Query.CastError (400) and an unknown id raises Ecto.NoResultsError (404).
  # Note: this shows unpublished posts too. Add a published_at check or an owner
  # check if drafts must stay private.
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
# <.header>
#   {@post.title}
#   <:subtitle>by {@post.user.name}</:subtitle>
# </.header>
#
# <div>{@post.body}</div>

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (inside the browser scope)
# ---------------------------------------------------------------------------
# get "/posts/:id", PostController, :show

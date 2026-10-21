# Assumptions (not verifiable here, no Phoenix/Ecto installed):
#   - MyApp.Repo exists; MyApp.Accounts.User has :name.
#   - MyApp.Audit.Log has :action (string) and :description (string) fields and
#     no required fields beyond those. Adjust the Log attrs in publish_post/2 to match.
#   - The posts table may not exist yet; migration 1 creates it. If it already
#     exists, skip migration 1 and keep migration 2.

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261021000001_create_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :body, :text, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # Serves "one user's posts, newest first".
    create index(:posts, [:user_id, :inserted_at])
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261021000002_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Plain SQL in the backfill so the migration does not depend on the Post schema,
  # which may change after this migration is written.
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL"
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

  # published_at and user_id are deliberately not cast from form params:
  # the owner is set by the context and publishing goes through publish_changeset/2.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
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

  @doc """
  Creates a post owned by `user` from form params.
  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Lists a user's posts, newest first, with the author loaded in the same query
  (one SQL statement, no per-post author lookup).
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

  @doc """
  Fetches a post with its author. Raises `Ecto.NoResultsError` if missing,
  which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row, in one transaction.
  Returns `{:ok, post}`, `{:error, :already_published}`, or `{:error, changeset}`.
  """
  def publish_post(%Post{published_at: %DateTime{}}, %User{}), do: {:error, :already_published}

  def publish_post(%Post{} = post, %User{} = actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:log, fn %{post: published} ->
      Ecto.Changeset.change(%Log{}, %{
        action: "post.published",
        description:
          "User #{actor.id} published post #{published.id} (#{published.title}) at #{DateTime.to_iso8601(now)}"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (add inside the browser scope)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

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
#     <h1>{@post.title}</h1>
#     <p>By {@post.user.name}</p>
#     <div>{@post.body}</div>

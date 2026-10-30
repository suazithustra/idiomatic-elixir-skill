# Assumptions (not verifiable here, adjust if wrong):
#   * The posts table already exists with title, body, user_id, inserted_at, updated_at.
#   * MyApp.Audit.Log has fields :action, :user_id and :details, and a changeset/2.
#   * MyApp.Accounts.User has `has_many :posts, MyApp.Blog.Post` (optional; nothing below needs it).

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

    # Existing posts count as published at the moment they were created.
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

  # Form changeset. published_at and user_id are not cast, so a form
  # cannot publish a post or assign it to another user.
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

  @doc "Returns a changeset for a new post form."
  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Creates a draft post owned by `user` from form params.

  The owner comes from `user`, never from `attrs`.
  """
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists a user's posts, newest first, with the author loaded in the same query.
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]
    )
  end

  @doc """
  Gets a post by id with its author. Raises `Ecto.NoResultsError` (404 in
  Phoenix) if missing, and `Ecto.Query.CastError` (400) if the id is not an integer.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and writes an audit log row in one transaction.

  The post row is locked first, so two concurrent calls cannot both publish it.

  Returns `{:ok, post}`, `{:error, :not_found}`, `{:error, :already_published}`,
  or `{:error, changeset}` if the update or the audit insert fails.
  """
  def publish_post(%Post{id: post_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:locked_post, fn repo, _changes ->
      case repo.one(from p in Post, where: p.id == ^post_id, lock: "FOR UPDATE") do
        nil -> {:error, :not_found}
        %Post{published_at: nil} = post -> {:ok, post}
        %Post{} -> {:error, :already_published}
      end
    end)
    |> Multi.update(:post, fn %{locked_post: post} ->
      Post.publish_changeset(post, now)
    end)
    |> Multi.insert(:audit_log, fn %{post: post} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        user_id: post.user_id,
        details: "Published post #{post.id} at #{DateTime.to_iso8601(now)}"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, reason, _changes_so_far} -> {:error, reason}
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (add inside the existing browser scope)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Serves drafts as well as published posts. If drafts must be private,
  # check post.published_at or the current user here.
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
# <Layouts.app flash={@flash}>
#   <h1>{@post.title}</h1>
#   <p>By {@post.user.name}</p>
#   <div>{@post.body}</div>
# </Layouts.app>

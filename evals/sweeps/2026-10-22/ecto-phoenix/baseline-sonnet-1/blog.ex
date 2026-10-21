# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
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

  # Only title and body come from the form. user_id and published_at are set
  # by the context, so a request cannot choose another author or publish itself.
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
  @moduledoc "Blog posts and their publishing."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params (title, body)."
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Returns a changeset for rendering a post form."
  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Lists one user's posts, newest first, with the author loaded in the same
  query so a page can show `post.title` and `post.user.name`.
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

  @doc "Gets a post by id with its author. Raises `Ecto.NoResultsError` if missing."
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post: sets `published_at` to now and writes an audit log row,
  in one transaction. If either step fails, neither is saved.

  Returns `{:ok, post}`, `{:error, :already_published}`, or `{:error, changeset}`.
  """
  def publish_post(%Post{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    # Re-read the row inside the transaction and lock it, so two concurrent
    # publishes cannot both succeed and write two audit rows.
    |> Multi.run(:current, fn repo, _changes ->
      case repo.one(from p in Post, where: p.id == ^id, lock: "FOR UPDATE") do
        nil -> {:error, :not_found}
        %Post{published_at: nil} = post -> {:ok, post}
        %Post{} -> {:error, :already_published}
      end
    end)
    |> Multi.update(:post, fn %{current: post} ->
      Ecto.Changeset.change(post, published_at: now)
    end)
    |> Multi.insert(:audit_log, fn %{post: post} ->
      # ASSUMPTION: MyApp.Audit.Log has :action, :user_id and :metadata (map)
      # fields. Adjust to the real schema.
      Log.changeset(%Log{}, %{
        action: "post.published",
        user_id: post.user_id,
        metadata: %{post_id: post.id, title: post.title, published_at: now}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (inside the browser-scoped block)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # `get_post!/1` raises Ecto.NoResultsError for an unknown id, which Phoenix
  # renders as a 404. A non-numeric id raises Ecto.Query.CastError, rendered
  # as a 400.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_html/show.html.heex
# ---------------------------------------------------------------------------
# <h1>{@post.title}</h1>
# <p>By {@post.user.name}</p>
# <div>{@post.body}</div>

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261021000000_create_posts.exs
# (Skip this one if the posts table already exists in your database.)
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

    create index(:posts, [:user_id, :inserted_at])
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261021000100_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # up/down instead of change: the backfill is a data change that needs
  # an explicit reverse (dropping the column removes the data anyway).
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime, null: true
    end

    # Make sure the column exists before the UPDATE runs.
    flush()

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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for form params. `published_at` and `user_id` are deliberately
  not cast: a form must not be able to publish a post or reassign its owner.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset used only by `MyApp.Blog.publish_post/1`."
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc "The Blog context."

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  The owner comes from `user`, never from `attrs`.
  """
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists one user's posts, newest first, with the author loaded in the same
  query (one SQL statement, no per-post author lookup).
  """
  def list_posts_for_user(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]
    )
  end

  @doc """
  Gets a post by id with its author loaded. Raises `Ecto.NoResultsError`
  (rendered as a 404 by Phoenix) if there is no such post.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post: sets `published_at` to now and writes an audit log row.
  Both writes run in one transaction, so both happen or neither does.

  Returns `{:ok, %{post: post, audit_log: log}}`, or
  `{:error, step, reason, changes_so_far}`. Returns
  `{:error, :already_published}` if the post is already published.
  """
  def publish_post(%Post{published_at: %DateTime{}}), do: {:error, :already_published}

  def publish_post(%Post{} = post) do
    # :utc_datetime columns reject microseconds, so truncate.
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      # ASSUMPTION: MyApp.Audit.Log has `action`, `resource_type`,
      # `resource_id`, `details` fields and a `changeset/2`. Adjust to the
      # real schema.
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "post",
        resource_id: published.id,
        details: "Post #{published.id} published by user #{published.user_id}"
      })
    end)
    |> Repo.transaction()
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/router.ex  (add inside an existing scope "/", MyAppWeb)
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
# <Layouts.app flash={@flash}>
#   <h1>{@post.title}</h1>
#   <p>By {@post.user.name}</p>
#   <div>{@post.body}</div>
# </Layouts.app>

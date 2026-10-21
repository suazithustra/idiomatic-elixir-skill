# ==============================================================================
# File: priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
# ==============================================================================
#
# The posts table already exists (title, body, user_id, timestamps).
#
# The backfill runs in the same migration, inside the same transaction as the
# ALTER TABLE. After this deploy, a NULL published_at means "draft", so a
# backfill run later with `WHERE published_at IS NULL` would wrongly publish
# drafts created in the meantime. Raw SQL keeps the migration independent of
# the Post schema, which will change over time.
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ==============================================================================
# File: lib/my_app/blog/post.ex
# ==============================================================================
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    # Must match the type the existing posts table was created with.
    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for form input. `user_id` and `published_at` are deliberately not
  cast: the owner is set by the context and publishing goes through
  `MyApp.Blog.publish_post/1`.
  """
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

# ==============================================================================
# File: lib/my_app/blog.ex
# ==============================================================================
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
  Returns the given user's posts, newest first, with `:user` preloaded so the
  page can show each post's author name. Uses a single query.
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user_id,
        # id breaks ties between posts inserted in the same second.
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]
    )
  end

  @doc """
  Gets a single post with its author preloaded.

  Raises `Ecto.NoResultsError` if the post does not exist, which Phoenix
  renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log, in one
  transaction. If either write fails, neither is kept.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def publish_post(%Post{} = post) do
    # :utc_datetime columns reject microseconds.
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: post} ->
      # Assumes MyApp.Audit.Log.changeset/2; match these keys to the real
      # audit_logs columns.
      Log.changeset(%Log{}, %{
        action: "post.published",
        user_id: post.user_id,
        target_type: "post",
        target_id: post.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end
end

# ==============================================================================
# File: lib/my_app_web/router.ex (add inside the existing browser scope)
# ==============================================================================
#
#   get "/posts/:id", PostController, :show

# ==============================================================================
# File: lib/my_app_web/controllers/post_controller.ex
# ==============================================================================
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Shows drafts as well as published posts. If this route is public, check
  # `post.published_at` (or the current user) before rendering.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ==============================================================================
# File: lib/my_app_web/controllers/post_html.ex
# ==============================================================================
#
# The template is inlined here as a function component. With a separate file,
# use `embed_templates "post_html/*"` and put the HEEx below in
# lib/my_app_web/controllers/post_html/show.html.heex.
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <article>
        <h1>{@post.title}</h1>
        <p>
          By {@post.user.name}
          <span :if={@post.published_at}>
            · {Calendar.strftime(@post.published_at, "%B %-d, %Y")}
          </span>
        </p>
        <div class="whitespace-pre-line">{@post.body}</div>
      </article>
    </Layouts.app>
    """
  end
end

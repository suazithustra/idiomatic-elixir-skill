# ==============================================================================
# lib/my_app/blog/post.ex
# ==============================================================================
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
  Changeset for user-editable fields.

  `user_id` and `published_at` are deliberately not cast: the owner is set by
  the context from the authenticated user, and publishing goes through
  `MyApp.Blog.publish_post/1`.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
  end
end

# ==============================================================================
# lib/my_app/blog.ex
# ==============================================================================
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Audit
  alias MyApp.Blog.Post

  @doc """
  Gets a single post with its author preloaded.

  Raises `Ecto.NoResultsError` if the post does not exist.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Lists the given user's posts, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    from(p in Post,
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    user
    |> Ecto.build_assoc(:posts)
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a changeset for tracking post changes (e.g. for forms).
  """
  def change_post(%Post{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  @doc """
  Publishes a post and records an audit log entry in a single transaction.

  Returns `{:ok, post}` or `{:error, changeset}`; if either write fails,
  neither is persisted.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      # Adjust the field names to match the existing MyApp.Audit.Log schema.
      Audit.Log.changeset(%Audit.Log{}, %{
        action: "post.published",
        user_id: published.user_id,
        resource_type: "post",
        resource_id: published.id,
        metadata: %{published_at: published.published_at}
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
# lib/my_app/accounts/user.ex  (addition inside the existing schema block)
# ==============================================================================
# Required by Ecto.build_assoc(user, :posts) in MyApp.Blog.create_post/2:
#
#     has_many :posts, MyApp.Blog.Post

# ==============================================================================
# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
# ==============================================================================
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Make sure the column exists before backfilling.
    flush()

    # Backfill existing posts. On rollback this is a no-op and the column
    # removal (the reverse of the alter above) discards the data.
    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL", ""
  end
end

# ==============================================================================
# lib/my_app_web/controllers/post_controller.ex
# ==============================================================================
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # A missing id raises Ecto.NoResultsError, which Phoenix renders as a 404.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ==============================================================================
# lib/my_app_web/controllers/post_html.ex
# ==============================================================================
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

# ==============================================================================
# lib/my_app_web/controllers/post_html/show.html.heex
# ==============================================================================
# <Layouts.app flash={@flash}>
#   <.header>
#     {@post.title}
#     <:subtitle>by {@post.user.name}</:subtitle>
#   </.header>
#   <article class="prose">{@post.body}</article>
# </Layouts.app>

# ==============================================================================
# lib/my_app_web/router.ex  (addition inside the browser scope)
# ==============================================================================
#     get "/posts/:id", PostController, :show

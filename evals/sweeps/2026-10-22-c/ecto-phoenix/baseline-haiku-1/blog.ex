# Blog posts: schema, context, migration, controller, and route.
# Each part below is labeled with the file it would live in.
# Not compiled: Phoenix and Ecto are not installed here.
#
# Assumptions about existing code (adjust if they differ):
#   - MyApp.Accounts.User exists with a `name` field.
#   - MyApp.Audit.Log has a `changeset/2` and accepts the fields used in
#     publish_post/1 (action, resource_type, resource_id, user_id).
#   - The posts table already exists with title, body, user_id, and timestamps.
#   - Timestamps use :utc_datetime_usec (the Phoenix 1.8 default).
#   - MyAppWeb.BlogHTML defines show/1 and its template, which are not included here.
#   - No separate script is needed: the migration below does the backfill.


# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published_at])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
  end
end


# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists a user's posts newest first, with the author preloaded for display.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where([p], p.user_id == ^user.id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises if not found.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post: sets published_at to now and writes an audit log row.
  Both happen in one transaction, so either both succeed or neither does.
  """
  def publish_post(%Post{} = post) do
    changeset = Post.changeset(post, %{published_at: DateTime.utc_now()})

    Multi.new()
    |> Multi.update(:post, changeset)
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "Post",
        resource_id: published.id,
        user_id: published.user_id
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
# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime_usec
    end

    # Existing posts were already visible, so treat them as published when they were created.
    # The down step is a no-op because dropping the column removes the data.
    execute(
      "UPDATE posts SET published_at = inserted_at",
      ""
    )
  end
end


# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/blog_controller.ex
# Renders MyAppWeb.BlogHTML.show/1 (the template is not included here).
# ---------------------------------------------------------------------------
defmodule MyAppWeb.BlogController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end


# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex (add inside the existing browser scope)
# ---------------------------------------------------------------------------
#   get "/posts/:id", BlogController, :show

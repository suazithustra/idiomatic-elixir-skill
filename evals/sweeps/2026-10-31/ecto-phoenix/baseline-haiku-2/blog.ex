# File: priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
# Assumes the posts timestamps use :utc_datetime (Phoenix 1.8 generator default).
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts get their inserted_at as the publish time.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# File: lib/my_app/blog/post.ex
# Assumes the posts table already exists with title, body, user_id, and timestamps.
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

  # Form params never set user_id or published_at.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end

  def publish_changeset(post) do
    published_at = DateTime.utc_now() |> DateTime.truncate(:second)
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/audit/log.ex
# Assumed shape, not verified: the existing schema has a changeset/2 that casts
# :action, :user_id, :resource_type, and :resource_id. Adjust the fields to match.
#
# defmodule MyApp.Audit.Log do
#   use Ecto.Schema
#   import Ecto.Changeset
#
#   schema "audit_logs" do
#     field :action, :string
#     field :resource_type, :string
#     field :resource_id, :integer
#     belongs_to :user, MyApp.Accounts.User
#     timestamps(type: :utc_datetime)
#   end
#
#   def changeset(log, attrs) do
#     log
#     |> cast(attrs, [:action, :resource_type, :resource_id, :user_id])
#     |> validate_required([:action, :resource_type, :resource_id, :user_id])
#   end
# end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params (string keys).
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists one user's posts, newest first, with the author preloaded.
  "Newest" means inserted_at descending; id breaks ties.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post with its author preloaded. Raises Ecto.NoResultsError if missing.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and writes an audit log row in one transaction.
  Returns {:ok, post} or {:error, reason}. If either write fails, neither is kept.
  The audit row records `actor` as the user who did the action.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "post",
        resource_id: published.id,
        user_id: actor.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/controllers/post_html.ex
# Expects a template at lib/my_app_web/controllers/post_html/show.html.heex
# that uses @post.title, @post.body, and @post.user.name.
#
# defmodule MyAppWeb.PostHTML do
#   use MyAppWeb, :html
#   embed_templates "post_html/*"
# end

# File: lib/my_app_web/router.ex (inside the browser scope)
# get "/posts/:id", PostController, :show

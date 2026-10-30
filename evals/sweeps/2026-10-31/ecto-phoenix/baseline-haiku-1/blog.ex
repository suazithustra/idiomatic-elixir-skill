# Assumptions (not verified, Phoenix and Ecto not installed):
#   - posts.inserted_at and posts.updated_at are :utc_datetime (timestamp(0)).
#   - MyApp.Accounts.User has a :name field.
#   - MyApp.Audit.Log has :action, :resource_type, :resource_id and :user_id fields.
#     Adjust the field names in publish_post/1 to match the real schema.

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
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

  # published_at is not cast here, so form params cannot set it.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end

  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
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

  @doc "Creates a post owned by `user` from form params."
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists one user's posts, newest first, with the author preloaded."
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc "Gets one post by id with its author preloaded. Raises if not found."
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post: sets published_at to now and inserts an audit log row.
  Both writes run in one transaction, so either both happen or neither does.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      %Log{
        action: "post.published",
        resource_type: "post",
        resource_id: published.id,
        user_id: published.user_id
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/<timestamp>_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts get their inserted_at as published_at.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex (add inside the browser scope)
#   get "/posts/:id", PostController, :show
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Raises Ecto.NoResultsError (404) when the id does not exist.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_html.ex
# (template: lib/my_app_web/controllers/post_html/show.html.heex)
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

# Every part of the blog feature, in one file. Each section starts with a
# comment naming the file it would live in inside the Phoenix app.
#
# Assumptions (not verified; the code could not be compiled here):
# - The posts table already exists with title, body, user_id, inserted_at,
#   and updated_at columns.
# - MyApp.Audit.Log has changeset/2 and the fields action, resource_type,
#   resource_id, and user_id. Rename these to match the real schema.
# - MyApp.Accounts.User has a name field (used by the page, not this code).

# ---- File: lib/my_app/blog/post.ex ----
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

  # Form fields only. published_at is not cast here, so it can only be set
  # through MyApp.Blog.publish_post/1, which also writes the audit row.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# ---- File: lib/my_app/blog.ex ----
defmodule MyApp.Blog do
  import Ecto.Query

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  # Creates a post owned by the given user. attrs are form params.
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  # Returns one user's posts, newest first, with the author preloaded
  # so the page can show author.name.
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  # Raises Ecto.NoResultsError when the id is unknown.
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  # Sets published_at to now and inserts an audit row. Both run in one
  # transaction: if either step fails, neither change is kept.
  # The actor recorded in the audit row is the post's author.
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, published_at))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "post",
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

# ---- File: priv/repo/migrations/20261031120000_add_published_at_to_posts.exs ----
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts were already visible, so treat their creation time as
    # their publication time.
    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---- File: lib/my_app_web/controllers/post_controller.ex ----
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Route, inside the browser scope in lib/my_app_web/router.ex:
  #   get "/posts/:id", PostController, :show
  #
  # Renders with PostHTML (lib/my_app_web/controllers/post_html.ex), which
  # needs a show/1 function or a show.html.heex template.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

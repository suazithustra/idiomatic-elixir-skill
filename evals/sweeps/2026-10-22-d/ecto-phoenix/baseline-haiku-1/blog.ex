# Assumptions (not verified, Phoenix/Ecto not installed):
#   - posts table exists with inserted_at, updated_at, title, body, user_id
#   - MyApp.Accounts.User has a :name field (no has_many needed)
#   - MyApp.Audit.Log has :action, :resource, :resource_id, :user_id fields
#     (adjust the struct in publish_post/1 to match the real schema)
#   - Router is in lib/my_app_web/router.ex; templates are standard Phoenix 1.8 HTML modules

# lib/my_app/blog/post.ex
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

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end

  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  # Publishes the post and writes the audit row in one transaction:
  # if either write fails, both are rolled back.
  def publish_post(%Post{} = post) do
    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, DateTime.utc_now()))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      %Log{
        action: "post.published",
        resource: "post",
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

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# lib/my_app_web/router.ex (inside the browser scope)
#   get "/posts/:id", PostController, :show

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime_usec
    end

    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

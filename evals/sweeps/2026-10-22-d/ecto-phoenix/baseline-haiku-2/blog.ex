# Assumes MyApp.Audit.Log already has changeset/2 and fields action, resource,
# resource_id and user_id. Adjust publish_post/1 if its fields differ.

# lib/my_app/blog/post.ex
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

  # Only title and body come from user input. published_at is set by
  # MyApp.Blog.publish_post/1, never from form params.
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

# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
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

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  # Newest first by inserted_at. The id tie-breaker keeps order stable
  # for posts created in the same second.
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  # Sets published_at and writes the audit row in one transaction, so
  # either both happen or neither does.
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, published_at))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource: "post",
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

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Needs a route in lib/my_app_web/router.ex, e.g. get "/posts/:id", PostController, :show
  # Renders the :show template from lib/my_app_web/controllers/post_html/show.html.heex.
  # A missing id raises Ecto.NoResultsError, which Phoenix turns into a 404.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app/blog/post.ex

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

  # Form-facing fields only. user_id is set in the context, never from params.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end

  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
  end
end

# File: lib/my_app/blog.ex

defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Accounts.User

  # Creates a post owned by `user` from form params (string keys).
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  # One user's posts, newest first. Preloads the author so the page can show names.
  def list_user_posts(%User{} = user) do
    from(p in Post,
      where: p.user_id == ^user.id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  # Raises Ecto.NoResultsError when missing; Phoenix renders that as a 404.
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  # Sets published_at to now and inserts an audit row in one transaction.
  # Either both happen or neither does.
  #
  # Assumes MyApp.Audit.Log has changeset/2 and the fields :action,
  # :subject_type, :subject_id and :user_id. Adjust to the real schema.
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        subject_type: "Post",
        subject_id: published.id,
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

# File: priv/repo/migrations/20261021120000_add_published_at_to_posts.exs

defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Assumes posts.inserted_at is a timestamp type (utc_datetime or naive_datetime).
  # Existing rows get published_at = inserted_at, so they count as published.
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

# File: lib/my_app_web/controllers/post_controller.ex
#
# Route, inside the browser scope in lib/my_app_web/router.ex:
#   get "/posts/:id", PostController, :show
#
# Renders with MyAppWeb.PostHTML, which needs a show.html.heex template
# (or embed_templates "post_html/*" in that module).

defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

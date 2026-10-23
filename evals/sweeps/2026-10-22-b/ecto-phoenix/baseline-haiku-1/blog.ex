# Assumptions (not verified; the project is not available here):
#   - the `posts` table exists with `title`, `body`, `user_id`, and timestamps
#   - MyApp.Audit.Log has a `changeset/2` that casts :action, :resource,
#     :resource_id, and :user_id. Adjust the audit attrs in publish_post/1 if not.
#   - MyApp.Accounts.User has the `name` field.
#
# Parts are listed in the order they would appear in the project. Each one
# is labeled with the file it would live in.

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts are treated as published at the time they were inserted.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

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

  # published_at is deliberately not cast here. Form params can't set it;
  # only publish_post/1 in the context does.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
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

  @doc """
  Creates a post for `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises if it doesn't exist.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and records an audit log entry. Both happen in
  one transaction, so neither is kept without the other.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(:post, Ecto.Changeset.change(post, published_at: now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource: "post",
        resource_id: to_string(published.id),
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

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# lib/my_app_web/controllers/post_html.ex (with lib/my_app_web/controllers/post_html/show.html.heex)
#
# The route, in lib/my_app_web/router.ex inside the browser scope:
#   get "/posts/:id", PostController, :show
#
# Ecto.NoResultsError from Repo.get! becomes a 404 through Plug.Exception.
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

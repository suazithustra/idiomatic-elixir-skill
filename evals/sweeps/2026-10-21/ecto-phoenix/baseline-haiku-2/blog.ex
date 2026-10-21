# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
#
# Adds published_at to posts. Existing rows get published_at = inserted_at.
# Assumes the posts table already exists with inserted_at, and that its
# timestamp columns match the type used below.

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

# File: lib/my_app/blog/post.ex

defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    # Use the same timestamp type as the existing posts migration.
    timestamps(type: :utc_datetime)
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
end

# File: lib/my_app/blog.ex

defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Audit
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post

  @doc """
  Creates a post for `user` from form params (string keys).
  """
  def create_post(%MyApp.Accounts.User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns one post by id, with its author preloaded.
  Raises Ecto.NoResultsError if the post does not exist.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Lists `user`'s posts, newest first, with the author preloaded
  so the page can show each title and the author's name.
  """
  def list_user_posts(%MyApp.Accounts.User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Sets published_at to now and writes an audit log row.
  Both happen in one transaction: either both are saved or neither is.
  """
  def publish_post(%Post{} = post) do
    published_at =
      DateTime.utc_now()
      |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with {:ok, post} <- update_published_at(post, published_at),
           {:ok, _log} <- insert_publish_log(post) do
        post
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_published_at(post, published_at) do
    post
    |> Ecto.Changeset.change(published_at: published_at)
    |> Repo.update()
  end

  # Field names on Log (action, resource, resource_id, user_id) are assumed.
  # Change them to match MyApp.Audit.Log.
  defp insert_publish_log(%Post{id: post_id, user_id: user_id}) do
    %Log{
      action: "post.published",
      resource: "post",
      resource_id: post_id,
      user_id: user_id
    }
    |> Repo.insert()
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

# File: lib/my_app_web/router.ex (inside the scope that uses the :browser pipeline)
#
#   get "/posts/:id", PostController, :show
#
# File: lib/my_app_web/controllers/post_html.ex
# Phoenix 1.8 renders :show with PostHTML, so this module and
# lib/my_app_web/controllers/post_html/show.html.heex must exist.

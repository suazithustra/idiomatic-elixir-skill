# ---------------------------------------------------------------------------
# Assumptions to check before running:
# - posts.inserted_at is :utc_datetime (Phoenix 1.8 generator default).
#   If it is :naive_datetime or :utc_datetime_usec, change the published_at
#   type to match.
# - MyApp.Audit.Log has a changeset/2 function and columns action,
#   resource_type, resource_id, user_id. Rename them if your table differs.
# - The User schema has no required has_many association; this code does
#   not need one.
# ---------------------------------------------------------------------------

# Lives in: priv/repo/migrations/20261023120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Backfill existing rows. Runs inside the migration's transaction.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# Lives in: lib/my_app/blog/post.ex
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

  # user_id is not cast. The context sets the owner, never form params.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
end

# Lives in: lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post

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

  @doc "Gets a post by id with its author. Raises Ecto.NoResultsError if missing."
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post. Sets published_at and inserts an audit log row in one
  transaction, so either both happen or neither does.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Ecto.Changeset.change(post, published_at: now))
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
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end
end

# Lives in: lib/my_app_web/controllers/post_controller.ex
#
# Also needed:
# - Route in lib/my_app_web/router.ex, inside the browser scope:
#     get "/posts/:id", PostController, :show
# - Template module lib/my_app_web/controllers/post_html.ex with a show/1
#   function (or show.html.heex) that uses @post.title, @post.body, and
#   @post.user.name.
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

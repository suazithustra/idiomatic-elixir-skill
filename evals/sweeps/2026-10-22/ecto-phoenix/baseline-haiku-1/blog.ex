# Blog posts: schema, context, migration, controller.
# Not compiled (Phoenix and Ecto are not installed). Each part is labeled
# with the file it would live in. Assumptions are marked in comments.

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
# Assumes the posts table uses timestamps(type: :utc_datetime), which is the
# Phoenix 1.8 generator default. If it uses naive timestamps, change both the
# migration type and the schema timestamps type to match.

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

  # Used for create and edit from form params. published_at is not cast,
  # so a form cannot set it directly.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  # Used only by MyApp.Blog.publish_post/2.
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
# Assumes MyApp.Audit.Log has the fields :action, :user_id, :resource_type,
# and :resource_id, and that it uses an inserted_at timestamp. Change the
# struct fields in publish_post/2 to match the real schema.

defmodule MyApp.Blog do
  import Ecto.Query

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Blog.Post
  alias MyApp.Audit.Log

  @doc """
  Creates a post for `user` from form params.
  """
  def create_post(user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns one user's posts, newest first, with the author preloaded
  so the page can show the author's name.
  """
  def list_user_posts(user_id) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches one post by id, with its author. Raises Ecto.NoResultsError if
  the post does not exist (Phoenix returns 404).
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` and records an audit log row for `actor`.

  Both the published_at update and the audit insert run in one
  transaction. If either fails, neither is saved.

  Returns {:ok, post} or {:error, changeset_or_value}.
  """
  def publish_post(%Post{} = post, actor) do
    published_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, published_at))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      %Log{
        action: "post.published",
        user_id: actor.id,
        resource_type: "Post",
        resource_id: published.id
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, failed_value, _changes} -> {:error, failed_value}
    end
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
# The column is added as nullable, then backfilled from inserted_at for all
# existing rows. Rolling back drops the column and its data.

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

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
# Route, inside the browser scope in lib/my_app_web/router.ex:
#
#   get "/posts/:id", PostController, :show
#
# The view needs lib/my_app_web/controllers/post_html.ex with a `show/1`
# function (or a post_html/show.html.heex template) that reads @post.
# @post.user.name is the author's name.

defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

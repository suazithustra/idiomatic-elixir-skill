# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    timestamps()
  end

  # Form params only: user_id and published_at are never cast from user input.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
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

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists a user's posts, newest first, with the author preloaded (one extra query,
  no N+1) so the page can show `post.title` and `post.user.name`.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id, raising `Ecto.NoResultsError` (rendered as 404) if missing.
  """
  def get_post!(id), do: Post |> Repo.get!(id) |> Repo.preload(:user)

  @doc """
  Publishes a post and records an audit log entry in a single transaction.

  Assumes `MyApp.Audit.Log` has `:action` and `:description` string fields and a
  `changeset/2` that casts and requires them; adjust to the real schema.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, published_at))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Log.changeset(%Log{}, %{
        action: "post.published",
        description: "Published post #{published.id} (#{published.title})"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end
end

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Backfill: existing posts count as published when they were inserted.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
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

# lib/my_app_web/router.ex (inside the :browser scope)
#
#     get "/posts/:id", PostController, :show
#
# lib/my_app_web/controllers/post_html.ex needs `use MyAppWeb, :html` and
# `embed_templates "post_html/*"`, with post_html/show.html.heex rendering
# @post.title, @post.body and @post.user.name.

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

  @doc """
  Changeset for form params. `user_id` and `published_at` are deliberately not
  cast: the owner comes from the caller and publishing goes through
  `MyApp.Blog.publish_post/1`.
  """
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

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc "Blog posts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params."
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Returns a changeset for tracking form changes."
  def change_post(%Post{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  @doc """
  Lists a user's posts, newest first, with the author loaded (single query)
  so the page can show each title and `post.user.name`.
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]
    )
  end

  @doc "Gets a single post with its author. Raises `Ecto.NoResultsError` if missing."
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and writes an audit log entry, atomically.

  Assumes `MyApp.Audit.Log` has `:action`, `:resource`, `:resource_id` and
  `:user_id` fields; adjust the map below to the real schema.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.publish_changeset(post, now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Ecto.Changeset.change(%Log{}, %{
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

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# lib/my_app_web/router.ex  (inside the :browser scope)
#
#     get "/posts/:id", PostController, :show
#
# lib/my_app_web/controllers/post_html.ex  (plus post_html/show.html.heex)
#
#     defmodule MyAppWeb.PostHTML do
#       use MyAppWeb, :html
#       embed_templates "post_html/*"
#     end

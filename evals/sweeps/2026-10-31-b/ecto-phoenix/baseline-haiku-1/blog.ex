# Blog posts for a Phoenix 1.8 / Ecto / PostgreSQL app (MyApp).
#
# This file holds several parts. Each part has a comment line above it naming
# the file it would live in in a real project.
#
# Assumptions (not verified, since the project is not available here):
#   - posts table exists with title (string), body (string), user_id (references users),
#     and timestamps(type: :utc_datetime).
#   - MyApp.Accounts.User has a name field and belongs to nothing new.
#   - MyApp.Audit.Log schema has fields: action, resource_type, resource_id, user_id,
#     and a changeset/2 function. Adjust the attrs in publish_post/1 to match the real schema.
#   - The router has: get "/posts/:id", PostController, :show

# File: priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Adds the column, then backfills existing rows from inserted_at.
  # The column is nullable, so new drafts can stay unpublished.
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

    timestamps(type: :utc_datetime)
  end

  # published_at is not cast from form params. It is set only by MyApp.Blog.publish_post/1.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post

  # Creates a post owned by the given user. Form params may use string keys.
  def create_post(%MyApp.Accounts.User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  # Returns one user's posts, newest first. Preloads the author so the page can show their name.
  # Ties on inserted_at are broken by id so the order is stable.
  def list_user_posts(user_id) do
    from(p in Post,
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  # Raises Ecto.NoResultsError when the id does not exist. Phoenix turns that into a 404.
  def get_post!(id) do
    Repo.get!(from(p in Post, preload: [:user]), id)
  end

  # Sets published_at to now and writes an audit row. Both happen in one transaction,
  # so either both are saved or neither is.
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Post.changeset(post, %{}) |> Ecto.Changeset.change(published_at: now))
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

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Shows one post by the id in the URL, e.g. /posts/42.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/controllers/post_html.ex (plus post_html/show.html.heex)
# The show template would read @post.title, @post.body, and @post.user.name.
# No script is needed: the migration does the backfill.

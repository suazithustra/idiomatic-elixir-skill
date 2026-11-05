# Assumptions (not verified; no Phoenix or Ecto here to compile against):
#   - posts table timestamps are :utc_datetime (Phoenix 1.8 generator default).
#   - MyApp.Audit.Log has a changeset/2 and fields :action, :resource,
#     :resource_id, :user_id. Adjust the attrs in log_publish/1 to the real schema.
#   - "Newest first" means by inserted_at.

# ---------------------------------------------------------------------------
# Lives in: lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user.
  """

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
  Casts user-editable fields. `user_id` and `published_at` are not cast,
  so a form cannot set them.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at`. Publishing is done by `MyApp.Blog.publish_post/1`,
  which also writes the audit row.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# Lives in: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, showing, and publishing them.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first, with the author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post by id, with its author preloaded.

  Raises `Ecto.NoResultsError` when the post does not exist. `phoenix_ecto`
  turns that into a 404 response.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post`: sets `published_at` to now and writes an audit row.

  Both writes run in one transaction. If either fails, neither is kept.
  Returns `{:ok, post}` or `{:error, reason}`.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now(:second)

    Repo.transact(fn -> publish_and_log(post, published_at) end)
  end

  defp publish_and_log(post, published_at) do
    with {:ok, published} <- mark_published(post, published_at),
         {:ok, _log} <- log_publish(published) do
      {:ok, published}
    end
  end

  defp mark_published(post, published_at) do
    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  defp log_publish(post) do
    attrs = %{
      action: "post.published",
      resource: "posts",
      resource_id: post.id,
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# Lives in: priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
# Schema change only. The backfill is in its own data migration (below), per
# the project's split between schema and data migrations.
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---------------------------------------------------------------------------
# Lives in: priv/repo/data_migrations/20261105120100_backfill_posts_published_at.exs
# Run by hand after the schema migration:
#   mix ecto.migrate --migrations-path priv/repo/data_migrations
# Idempotent: rows already set are skipped. Raw SQL, so no app schema is used.
# The cutoff keeps drafts created after the schema migration (published_at NULL,
# unpublished) from being marked published. Use the schema migration's timestamp.
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.DataMigrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE posts
    SET published_at = inserted_at
    WHERE published_at IS NULL
      AND inserted_at < '2026-11-05 12:00:00'
    """)
  end

  def down, do: :ok
end

# ---------------------------------------------------------------------------
# Lives in: lib/my_app_web/controllers/blog_controller.ex
# Route in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", BlogController, :show
# Template: lib/my_app_web/controllers/blog_html/show.html.heex (uses @post.title,
# @post.user.name, @post.body). BlogHTML module is generated with the controller.
# ---------------------------------------------------------------------------
defmodule MyAppWeb.BlogController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

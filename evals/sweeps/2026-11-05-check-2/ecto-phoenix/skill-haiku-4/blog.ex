# === File: priv/repo/migrations/20261105120000_add_published_at_to_posts.exs ===

defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# === File: priv/repo/data_migrations/20261105120100_backfill_posts_published_at.exs ===
#
# Run by hand after the schema migration:
#   mix ecto.migrate --migrations-path priv/repo/data_migrations
# Raw SQL and no Post schema, so it keeps working if the schema changes.
# The IS NULL check makes it safe to rerun.

defmodule MyApp.Repo.Data.Migrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  def up do
    execute("UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL")
  end

  def down, do: :ok
end

# === File: lib/my_app/blog/post.ex ===

defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates the fields a user may set. `user_id` and `published_at`
  are not cast, so a request cannot set them.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Builds the change that sets `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# === File: lib/my_app/blog.ex ===

defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, reading and publishing them.
  """

  import Ecto.Query, only: [from: 2]

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
  Lists `user`'s posts, newest first, with the author preloaded.

  "Newest" means `inserted_at`. Ties break on `id`.
  """
  def list_user_posts(%User{} = user) do
    user
    |> user_posts_query()
    |> Repo.all()
  end

  @doc """
  Fetches a post and its author by id. Raises `Ecto.NoResultsError` when the
  post does not exist; Phoenix turns that into a 404 response.
  """
  def get_post!(id) do
    query = from(p in Post, preload: [:user])
    Repo.get!(query, id)
  end

  @doc """
  Sets `published_at` to now and inserts a `post.published` audit log row.
  Both writes commit together, or neither does.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, post} <- set_published_at(post),
           {:ok, _entry} <- record_audit(post, "post.published") do
        {:ok, post}
      end
    end)
  end

  defp user_posts_query(user) do
    from(p in Post,
      where: p.user_id == ^user.id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [:user]
    )
  end

  defp set_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has changeset/2 and fields :action, :subject_type,
  # :subject_id and :actor_id. Adjust to the real schema.
  defp record_audit(post, action) do
    entry = %{
      action: action,
      subject_type: "post",
      subject_id: post.id,
      actor_id: post.user_id
    }

    %Log{}
    |> Log.changeset(entry)
    |> Repo.insert()
  end
end

# === File: lib/my_app_web/controllers/post_controller.ex ===

defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# === File: lib/my_app_web/router.ex (inside the browser scope) ===
#
#   get "/posts/:id", PostController, :show

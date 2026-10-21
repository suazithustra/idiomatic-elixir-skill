# Each section starts with the file it would live in.
#
# Assumptions to check against the project:
#   - MyApp.Audit.Log has a changeset/2 and the fields :action, :record_type, :record_id.
#   - The posts table uses utc_datetime timestamps, as the schema below does.

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

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  `published_at` is not cast, so a request cannot set it. Use `publish_post/1`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Returns the user's posts, newest first, with the author preloaded.

  `id` breaks ties, because `inserted_at` has one-second precision.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Returns the post with the given id, with its author preloaded.

  Raises `Ecto.NoResultsError` when the post does not exist.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and inserts a `post.published` audit row.

  Both writes run in one transaction, so if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _log} <- record_audit(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp record_audit(post, action) do
    %Audit.Log{}
    |> Audit.Log.changeset(%{action: action, record_type: "post", record_id: post.id})
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # The backfill is in this migration because it was requested. It is raw SQL,
  # so it does not depend on application schema modules. Moving it to a separate
  # task would keep data changes out of the migration history.
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
# Route, in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

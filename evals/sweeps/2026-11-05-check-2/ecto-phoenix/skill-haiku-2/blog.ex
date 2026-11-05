# Assumptions (see each section):
#   - audit_logs has fields :action, :entity, :entity_id, :user_id, and
#     MyApp.Audit.Log has a changeset/2 that casts them. Adjust record_audit/2 if not.
#   - "Newest first" means by inserted_at, with id as the tie-breaker.
#   - The backfill is split from the schema change: it lives in priv/repo/data_migrations
#     (run by hand), following the project guidance for data changes.
#   - Ecto 3.13+ is required for Repo.transact/2.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user. `published_at` is nil until the post is published.
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

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Creates, lists, and publishes blog posts.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params. `published_at` is never cast from
  params, so a request cannot publish a post by itself.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author preloaded. Raises `Ecto.NoResultsError` when
  the post does not exist; `phoenix_ecto` turns that into a 404 response.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row. Both happen in one
  transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now(:second)
    changeset = Post.publish_changeset(post, published_at)

    Repo.transact(fn ->
      with {:ok, published} <- Repo.update(changeset),
           {:ok, _log} <- record_audit(published, "post_published") do
        {:ok, published}
      end
    end)
  end

  defp record_audit(%Post{} = post, action) do
    attrs = %{action: action, entity: "post", entity_id: post.id, user_id: post.user_id}

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/data_migrations/20261105120100_backfill_posts_published_at.exs
# Run after the schema migration, by hand:
#   mix ecto.migrate --migrations-path priv/repo/data_migrations
defmodule MyApp.Repo.DataMigrations.BackfillPostsPublishedAt do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1000

  def up, do: backfill(0)

  def down, do: :ok

  defp backfill(after_id) do
    %{rows: rows} =
      repo().query!(
        """
        UPDATE posts
        SET published_at = inserted_at
        WHERE id IN (
          SELECT id FROM posts
          WHERE id > $1 AND published_at IS NULL
          ORDER BY id
          LIMIT $2
        )
        RETURNING id
        """,
        [after_id, @batch_size]
      )

    case rows do
      [] ->
        :ok

      [_ | _] ->
        last_id = Enum.max(Enum.map(rows, fn [id] -> id end))
        backfill(last_id)
    end
  end
end

# lib/my_app_web/controllers/post_controller.ex
# Route, in the browser scope of lib/my_app_web/router.ex:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

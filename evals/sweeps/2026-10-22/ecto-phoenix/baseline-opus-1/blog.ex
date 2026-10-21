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

  # user_id and published_at are deliberately not cast from params: the owner
  # comes from the caller, and publishing goes through Blog.publish_post/1.
  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

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
  Lists `user`'s posts, newest first, with each post's author preloaded
  in the same query.
  """
  def list_user_posts(%User{id: user_id}) do
    query =
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]

    Repo.all(query)
  end

  @doc """
  Gets a post with its author preloaded.

  Raises `Ecto.NoResultsError` if the post does not exist.
  """
  def get_post!(id) do
    query =
      from p in Post,
        join: u in assoc(p, :user),
        where: p.id == ^id,
        preload: [user: u]

    Repo.one!(query)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row, in one transaction.

  Returns `{:ok, post}`, `{:error, :already_published}`, or
  `{:error, changeset}` if the audit log row is invalid.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Multi.new()
    |> Multi.run(:post, fn repo, _changes ->
      # The is_nil guard means two concurrent publishes cannot both succeed.
      query = from p in Post, where: p.id == ^post.id and is_nil(p.published_at), select: p

      case repo.update_all(query, set: [published_at: now, updated_at: now]) do
        {1, [published]} -> {:ok, published}
        {0, []} -> {:error, :already_published}
      end
    end)
    |> Multi.insert(:audit_log, fn %{post: published} ->
      # Attribute names are assumed; match them to the audit_logs columns.
      Log.changeset(%Log{}, %{
        action: "post.published",
        user_id: published.user_id,
        resource_type: "post",
        resource_id: published.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end

# File: priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/migrations/20261021120100_backfill_posts_published_at.exs
defmodule MyApp.Repo.Migrations.BackfillPostsPublishedAt do
  use Ecto.Migration
  import Ecto.Query

  # The backfill is kept apart from the ALTER TABLE above so the table is not
  # locked while rows are updated. It runs outside a transaction so each batch
  # commits on its own, and it can be re-run safely if interrupted. It uses the
  # "posts" table name, not the Post schema, so later schema changes cannot
  # break it.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 1_000

  def up, do: backfill(0)

  # Rolling back the previous migration drops the column and its data.
  def down, do: :ok

  defp backfill(last_id) do
    batch =
      from p in "posts",
        where: p.id > ^last_id and is_nil(p.published_at),
        order_by: p.id,
        limit: @batch_size,
        select: p.id

    query =
      from p in "posts",
        where: p.id in subquery(batch),
        update: [set: [published_at: p.inserted_at]],
        select: p.id

    case repo().update_all(query, []) do
      {0, _} -> :ok
      {_count, ids} -> backfill(Enum.max(ids))
    end
  end
end

# File: lib/my_app_web/router.ex (inside the existing browser scope)
#
#     get "/posts/:id", PostController, :show

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # An unknown id raises Ecto.NoResultsError (404) and a non-numeric id raises
  # Ecto.Query.CastError (400); phoenix_ecto maps both to those statuses.
  # Unpublished posts are shown too; add an author check here if drafts
  # should be private.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <article>
        <h1 class="text-2xl font-semibold">{@post.title}</h1>
        <p class="text-sm">
          By {@post.user.name}
          <span :if={@post.published_at}>
            on {Calendar.strftime(@post.published_at, "%Y-%m-%d")}
          </span>
        </p>
        <div class="mt-6 whitespace-pre-line">{@post.body}</div>
      </article>
    </Layouts.app>
    """
  end
end

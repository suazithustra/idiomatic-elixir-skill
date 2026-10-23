# Assumes the posts table already exists with title, body, user_id (FK to users,
# integer ids) and timestamps, as the task says the migration only adds published_at.

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
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
    # user_id and published_at are deliberately not cast: the author comes from
    # the caller, and publishing goes through MyApp.Blog.publish_post/1 so that
    # every publish is audited.
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post

  @doc """
  Creates a post authored by `user` from form params.

  The author is taken from `user`, never from `attrs`, so a submitted form
  cannot create a post on someone else's behalf.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first.

  The author is preloaded in the same query, so rendering each post's author
  name does not run one query per post.
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

  @doc """
  Gets a post that `viewer` is allowed to see: any published post, or the
  viewer's own unpublished post. `viewer` is `nil` for logged-out visitors.

  Raises `Ecto.NoResultsError` (rendered as a 404 by Phoenix) otherwise.
  """
  def get_visible_post!(id, viewer) do
    from(p in Post, where: p.id == ^id, preload: :user)
    |> visible_to(viewer)
    |> Repo.one!()
  end

  defp visible_to(query, nil), do: where(query, [p], not is_nil(p.published_at))

  defp visible_to(query, %User{id: user_id}),
    do: where(query, [p], not is_nil(p.published_at) or p.user_id == ^user_id)

  @doc """
  Publishes `post` and writes an audit log row, in one transaction.

  Returns `{:ok, post}`, `{:error, :already_published}` if the post is already
  published (or no longer exists), or `{:error, changeset}` if the audit log
  insert fails. On any error nothing is written.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now(:second)

    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post, now),
           {:ok, _log} <- Repo.insert(publish_log(published)) do
        {:ok, published}
      end
    end)
  end

  # The update only matches a row that is still unpublished, so two concurrent
  # publishes of the same post cannot both succeed and write two audit rows.
  defp mark_published(%Post{id: id}, now) do
    query = from p in Post, where: p.id == ^id and is_nil(p.published_at), select: p

    case Repo.update_all(query, set: [published_at: now, updated_at: now]) do
      {1, [post]} -> {:ok, post}
      {0, []} -> {:error, :already_published}
    end
  end

  # Field names assume MyApp.Audit.Log has action, user_id and a map metadata
  # field. Building the struct directly means a mismatch fails at compile time.
  defp publish_log(%Post{} = post) do
    %Log{
      action: "post.published",
      user_id: post.user_id,
      metadata: %{post_id: post.id, published_at: post.published_at}
    }
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261023120000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill runs in the next migration so this one
  # holds its table lock for milliseconds, not for a full-table UPDATE.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261023120100_backfill_posts_published_at.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.BackfillPostsPublishedAt do
  use Ecto.Migration
  import Ecto.Query

  # Each batch commits on its own, so a large table is never locked as a whole.
  @disable_ddl_transaction true
  @disable_migration_lock true
  @batch_size 1_000

  # Uses the "posts" table name, not MyApp.Blog.Post, so this migration keeps
  # working if the schema module changes later.
  def up, do: backfill_after(0)

  # Rolling back the previous migration drops the column.
  def down, do: :ok

  defp backfill_after(last_id) do
    batch =
      from p in "posts",
        where: p.id > ^last_id and is_nil(p.published_at),
        order_by: p.id,
        limit: @batch_size,
        select: p.id

    update =
      from p in "posts",
        where: p.id in subquery(batch),
        update: [set: [published_at: p.inserted_at]],
        select: p.id

    case repo().update_all(update, []) do
      {0, _} -> :ok
      {_count, ids} -> backfill_after(Enum.max(ids))
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex (inside the scope that pipes through :browser)
# ---------------------------------------------------------------------------
#   get "/posts/:id", PostController, :show

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # A missing post, or another user's unpublished post, raises
  # Ecto.NoResultsError, which phoenix_ecto turns into a 404. A non-numeric id
  # raises Ecto.Query.CastError, which phoenix_ecto turns into a 400.
  def show(conn, %{"id" => id}) do
    post = Blog.get_visible_post!(id, current_user(conn))
    render(conn, :show, post: post)
  end

  # phx.gen.auth in Phoenix 1.8 assigns :current_scope, which is nil when
  # nobody is logged in.
  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: user} -> user
      nil -> nil
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_html.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <article>
        <h1>{@post.title}</h1>
        <p>By {@post.user.name}</p>
        <div class="whitespace-pre-line">{@post.body}</div>
      </article>
    </Layouts.app>
    """
  end
end

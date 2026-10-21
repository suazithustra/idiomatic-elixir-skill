# Each part below names the file it would live in in a Phoenix 1.8 app.
#
# Parts:
#   lib/my_app/blog/post.ex                                   MyApp.Blog.Post schema
#   lib/my_app/blog.ex                                        MyApp.Blog context
#   priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
#                                                             migration (column only)
#   priv/repo/scripts/backfill_published_at.exs               one-time backfill script
#   lib/my_app_web/controllers/post_controller.ex             PostController.show/2
#
# Notes:
# - The backfill is a separate script, not part of the migration. The migration
#   only adds the column. Run the script right after `mix ecto.migrate`.
# - `MyApp.Audit.Log` was not provided. The fields used below (`action`,
#   `resource`, `resource_id`, `user_id`) are assumptions. Match them to the real
#   schema, and make sure `Log.changeset/2` exists or switch to `Repo.insert/1`.
# - `PostHTML.show/1` (the template for `render(conn, :show, post: post)`) is
#   assumed to exist.
# - Nothing here has been compiled against the project's dependencies.

# === lib/my_app/blog/post.ex ===
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc """
  Casts and validates the fields a user may set on a post.

  `user_id` and `published_at` are not cast. The context sets `user_id`
  on the struct, and `publish_changeset/2` sets `published_at`.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(%__MODULE__{} = post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# === lib/my_app/blog.ex ===
defmodule MyApp.Blog do
  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Returns the user's posts, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Sets `published_at` to the current time and writes an audit log row.

  Both writes run in one transaction. If either fails, both are rolled back.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <-
             post
             |> Post.publish_changeset(DateTime.utc_now())
             |> Repo.update(),
           {:ok, _log} <- log_action(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  @doc """
  Fetches a post and its author.

  Raises `Ecto.NoResultsError` when the post does not exist. Phoenix turns that
  into a 404. An ID that is not an integer raises `Ecto.Query.CastError`, which
  Phoenix turns into a 400.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  defp log_action(%Post{} = post, action) do
    %Log{}
    |> Log.changeset(%{
      action: action,
      resource: "post",
      resource_id: post.id,
      user_id: post.user_id
    })
    |> Repo.insert()
  end
end

# === priv/repo/migrations/20261021120000_add_published_at_to_posts.exs ===
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime_usec
    end
  end
end

# === priv/repo/scripts/backfill_published_at.exs ===
# Run once, after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Safe to run again: it only touches rows where published_at is still NULL.
import Ecto.Query

alias MyApp.Repo

query =
  from(p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]
  )

{count, _} = Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# === lib/my_app_web/controllers/post_controller.ex ===
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

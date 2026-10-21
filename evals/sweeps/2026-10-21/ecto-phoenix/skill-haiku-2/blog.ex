# Each section below names the file it would live in.
#
#   lib/my_app/blog/post.ex                                          Post schema
#   lib/my_app/blog.ex                                               Blog context
#   priv/repo/migrations/20261021120000_add_published_at_to_posts.exs  migration
#   priv/repo/scripts/backfill_published_at.exs                      one-off backfill
#   lib/my_app_web/controllers/post_controller.ex                    controller
#
# Assumptions to check against the real project:
#   - The posts table already exists with title, body, user_id, and timestamps.
#   - MyApp.Audit.Log has fields action, resource, resource_id, and actor_id.
#     Rename them to match the real schema.
#   - Repo.transact/2 needs Ecto 3.13 or later. On older Ecto, use Ecto.Multi.

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

  # user_id and published_at are not cast: the code sets them, not the form.
  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end

  @doc false
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query

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
  Lists the user's posts, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Returns the post with `id`, with its author preloaded.

  Raises `Ecto.NoResultsError` when no post exists. Phoenix turns that into a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and inserts an audit log row.

  The two writes share one transaction, so either both are saved or neither is.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _log} <- record_publish(published) do
        {:ok, published}
      end
    end)
  end

  # :utc_datetime rejects microseconds, so truncate to seconds.
  defp mark_published(post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  defp record_publish(%Post{} = post) do
    Repo.insert(%Log{
      action: "post.published",
      resource: "post",
      resource_id: post.id,
      actor_id: post.user_id
    })
  end
end

# priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill is in priv/repo/scripts/backfill_published_at.exs,
  # so the migration does not depend on application code or on data.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Safe to re-run: it only touches rows where published_at is still NULL.
import Ecto.Query

alias MyApp.Blog.Post
alias MyApp.Repo

{count, _} =
  Post
  |> where([p], is_nil(p.published_at))
  |> update([p], set: [published_at: p.inserted_at])
  |> Repo.update_all([])

IO.puts("Backfilled #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Route (in lib/my_app_web/router.ex, browser scope): get "/posts/:id", PostController, :show
  # Template: lib/my_app_web/controllers/post_html/show.html.heex
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# Each part below names the file it would live in. The parts are separated by
# those headers; split them into their files as shown.
#
# Assumptions about existing code, to adjust if they differ:
#   - the posts table already has title, body and user_id columns
#   - MyApp.Audit.Log.changeset/2 casts :action, :resource and :resource_id
#   - MyAppWeb.PostHTML renders a :show template with a @post assign

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
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

  # published_at is deliberately not cast: a form cannot set it, only publishing does.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end

  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publication.
  """

  import Ecto.Query, only: [where: 3, order_by: 3, preload: 3]

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
  Lists the user's posts newest first, with each author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post with its author preloaded. Raises `Ecto.NoResultsError` when missing.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and writes an audit log row. Both happen or neither does.
  """
  def publish_post(%Post{} = post) do
    changeset = Post.publish_changeset(post, DateTime.utc_now(:second))

    Repo.transact(fn -> write_publication(changeset) end)
  end

  defp write_publication(changeset) do
    with {:ok, post} <- Repo.update(changeset),
         {:ok, _log} <- insert_publish_log(post) do
      {:ok, post}
    end
  end

  defp insert_publish_log(post) do
    %Log{}
    |> Log.changeset(%{action: "post.published", resource: "post", resource_id: post.id})
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
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
# priv/repo/scripts/backfill_published_at.exs
# Run after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# The backfill lives here, not in the migration, so the migration stays schema-only.
# ---------------------------------------------------------------------------
import Ecto.Query

alias MyApp.Blog.Post
alias MyApp.Repo

{count, _} =
  Post
  |> where([p], is_nil(p.published_at))
  |> update([p], set: [published_at: p.inserted_at])
  |> Repo.update_all([])

IO.puts("Backfilled published_at on #{count} posts")

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# Route: get "/posts/:id", PostController, :show   (in lib/my_app_web/router.ex)
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

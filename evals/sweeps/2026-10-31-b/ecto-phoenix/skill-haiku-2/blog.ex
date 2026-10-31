# This file collects the parts of the blog feature. Each part names the
# project file it would live in. Split them into those files before compiling.
#
# Assumptions to check against the project:
#   - posts and audit_logs use Phoenix 1.8 default timestamps (:utc_datetime).
#   - MyApp.Audit.Log has a changeset/2 and the fields used in publish_post/1
#     (action, resource_type, resource_id, user_id). Rename them to match.

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
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
  Casts form params. `user_id` and `published_at` are not cast: the code sets
  them, so a request cannot set them.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261031120000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill of existing rows lives in
  # priv/repo/scripts/backfill_published_at.exs, because a data change in a
  # migration ties data logic to schema history.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---------------------------------------------------------------------------
# priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# ---------------------------------------------------------------------------
import Ecto.Query

alias MyApp.Repo

# Schemaless query, so the script does not depend on the Post schema's shape.
# Only rows still missing published_at are touched, so a second run changes nothing.
backfill =
  from(p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]
  )

{count, nil} = Repo.update_all(backfill, [])

IO.puts("Backfilled published_at on #{count} posts")

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Creates, lists, shows, and publishes blog posts.
  """

  import Ecto.Query, only: [from: 2, order_by: 3, preload: 3, where: 3]

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
  Lists one user's posts, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post with its author preloaded. Raises `Ecto.NoResultsError` when
  the post does not exist, which Phoenix turns into a 404.
  """
  def get_post!(id) do
    Repo.get!(from(p in Post, preload: [:user]), id)
  end

  @doc """
  Sets `published_at` to now and records an audit log row. Both writes run in
  one transaction: if either fails, neither is kept.
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
    now = DateTime.utc_now(:second)

    post
    |> Ecto.Changeset.change(published_at: now)
    |> Repo.update()
  end

  defp record_audit(post, action) do
    audit_attrs = %{
      action: action,
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    }

    Log.changeset(%Log{}, audit_attrs)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_html.ex and post_html/show.html.heex
# The show template reads @post.title, @post.body, and @post.user.name.
# ---------------------------------------------------------------------------
# defmodule MyAppWeb.PostHTML do
#   use MyAppWeb, :html
#
#   embed_templates "post_html/*"
# end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex, inside the browser scope
# ---------------------------------------------------------------------------
# get "/posts/:id", PostController, :show

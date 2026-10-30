# Each section below names the file it would live in. The code has not been
# compiled: Phoenix and Ecto are not installed in the environment that wrote it.
#
# Assumptions to check against the project:
#   - MyApp.Audit.Log has a changeset/2 that casts :action, :resource and :resource_id.
#   - MyApp.Repo is the repo used by the audit_logs table.
#   - MyAppWeb.PostHTML with a show/1 template exists (Phoenix 1.8 HTML controllers).

# ----------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ----------------------------------------------------------------------------

defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user. `published_at` is nil until the post is published.
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
  Casts the user-editable fields. `user_id` and `published_at` are not cast, so form
  params cannot change the author or the publish state.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
end

# ----------------------------------------------------------------------------
# lib/my_app/blog.ex
# ----------------------------------------------------------------------------

defmodule MyApp.Blog do
  @moduledoc """
  Writing, listing, and publishing blog posts.
  """

  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  The author is set on the struct before the cast, so the params cannot choose it.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each author preloaded.

  Ties on `inserted_at` are broken by `id`, so the order is stable.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises `Ecto.NoResultsError`
  when no post has that id.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row.

  Both writes run in one transaction. If either fails, the rollback undoes the
  other, and the function returns the error.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _entry} <- log_action(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp mark_published(%Post{} = post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp log_action(%Post{} = post, action) do
    %Log{}
    |> Log.changeset(%{action: action, resource: "post", resource_id: post.id})
    |> Repo.insert()
  end
end

# ----------------------------------------------------------------------------
# priv/repo/migrations/20261031120000_add_published_at_to_posts.exs
# ----------------------------------------------------------------------------

defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ----------------------------------------------------------------------------
# priv/repo/scripts/backfill_published_at.exs
# Run once with: mix run priv/repo/scripts/backfill_published_at.exs
#
# The backfill is a data change, so it lives in a script rather than in the
# migration. Run it right after the migration and before new posts are created:
# it sets published_at on every row where it is nil, including unpublished drafts.
# ----------------------------------------------------------------------------

import Ecto.Query

alias MyApp.Repo

query =
  from(p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]
  )

{count, _} = Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# ----------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# Route: get "/posts/:id", PostController, :show   (lib/my_app_web/router.ex)
# ----------------------------------------------------------------------------

defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

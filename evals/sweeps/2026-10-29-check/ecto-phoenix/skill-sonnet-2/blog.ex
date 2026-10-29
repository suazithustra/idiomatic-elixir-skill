# ---------------------------------------------------------------------------
# priv/repo/migrations/20261029000000_add_published_at_to_posts.exs
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
# priv/repo/backfill_post_published_at.exs
# Run once, right after the migration: mix run priv/repo/backfill_post_published_at.exs
# It uses the table name, not MyApp.Blog.Post, so it keeps working when the schema changes.
# Run it before anyone saves an unpublished post, or those posts get published too.
# ---------------------------------------------------------------------------
import Ecto.Query, only: [from: 2]

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(backfill, [])

IO.puts("Set published_at on #{count} existing posts")

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.
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
  Casts and validates form params. `user_id` and `published_at` are not
  castable: the context sets them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  @doc """
  Marks the post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their authors.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  Returns `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with `post.user` loaded.
  """
  def list_user_posts(%User{} = user) do
    query =
      from p in Post,
        join: author in assoc(p, :user),
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: author]

    Repo.all(query)
  end

  @doc """
  Gets a post with its author. Raises `Ecto.NoResultsError` when it does not
  exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_publication(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  # The field names of MyApp.Audit.Log (:action, :description, :user_id) are
  # assumed; adjust them to the real schema and its changeset.
  defp log_publication(post) do
    params = %{
      action: "post_published",
      description: "Published post #{post.id} (#{post.title})",
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(params)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex  (inside the browser scope)
#
#     get "/posts/:id", PostController, :show
# ---------------------------------------------------------------------------

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

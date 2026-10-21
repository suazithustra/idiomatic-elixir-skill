# ---------------------------------------------------------------------------
# priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
# Schema change only. Existing rows are filled by the script further down,
# not here, so this migration does not depend on application data logic.
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---------------------------------------------------------------------------
# priv/repo/backfill_posts_published_at.exs
# Run once after the migration: mix run priv/repo/backfill_posts_published_at.exs
# ---------------------------------------------------------------------------
# Queries the "posts" table by name instead of using MyApp.Blog.Post, so the
# script keeps working if the schema module changes later.
import Ecto.Query

{count, nil} =
  MyApp.Repo.update_all(
    from(p in "posts",
      where: is_nil(p.published_at),
      update: [set: [published_at: p.inserted_at]]
    ),
    []
  )

IO.puts("Set published_at on #{count} existing posts")

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc false

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

  # user_id and published_at are not cast, so a request cannot set them.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author loaded. Raises `Ecto.NoResultsError`
  when it does not exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records an audit log entry in the same transaction.

  Returns `{:error, :already_published}` if the post has a `published_at`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_publication(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp set_published_at(post) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has a changeset/2 that casts an :action string.
  defp log_publication(post) do
    %Audit.Log{}
    |> Audit.Log.changeset(%{action: "Published post #{post.id} (user #{post.user_id})"})
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
    render(conn, :show, post: Blog.get_post!(id))
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex  (inside the existing :browser scope)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

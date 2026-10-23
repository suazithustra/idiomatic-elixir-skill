# ---------------------------------------------------------------------------
# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
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
# priv/repo/backfill_published_at.exs
#
# Run once after the migration: mix run priv/repo/backfill_published_at.exs
# Kept out of the migration so schema history holds no data logic. It queries
# the "posts" table by name, so it does not depend on MyApp.Blog.Post.
# ---------------------------------------------------------------------------
import Ecto.Query

{count, _rows} =
  MyApp.Repo.update_all(
    from(p in "posts", where: is_nil(p.published_at), update: [set: [published_at: p.inserted_at]]),
    []
  )

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

    timestamps()
  end

  @doc """
  Changeset for form params. `user_id` and `published_at` are set by the
  context, so they are not cast.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset that marks a post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
#
# Assumes MyApp.Audit.Log has the fields :action, :subject_type and
# :subject_id; adjust to the real schema.
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded.
  """
  def list_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post with its author. Raises `Ecto.NoResultsError` if it does not
  exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records the action in the audit log. Both writes
  happen in one transaction.

  Returns `{:error, :already_published}` for a post that is already published.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post),
           {:ok, _log} <- log_publish(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp update_published_at(post) do
    now = DateTime.utc_now(:second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  defp log_publish(post) do
    Repo.insert(%Log{
      action: "post_published",
      subject_type: "post",
      subject_id: post.id
    })
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

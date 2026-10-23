# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/backfill_post_published_at.exs
# Run once after the migration: mix run priv/repo/backfill_post_published_at.exs
# Kept out of the migration so schema history does not depend on data logic.
# It queries the "posts" table directly instead of using MyApp.Blog.Post.
import Ecto.Query

{count, nil} =
  "posts"
  |> where([p], is_nil(p.published_at))
  |> update([p], set: [published_at: p.inserted_at])
  |> MyApp.Repo.update_all([])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app/blog/post.ex
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

  # user_id and published_at are set by the Blog context, so they are not cast.
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publication.
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
  Lists the user's posts, newest first, with each author loaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post with its author. Raises `Ecto.NoResultsError` if missing,
  which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records it in the audit log; both writes happen or neither.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  # Assumes Log has :action and :details fields and a Log.changeset/2.
  defp insert_publish_log(post) do
    %Log{}
    |> Log.changeset(%{action: "post.published", details: "post #{post.id}"})
    |> Repo.insert()
  end
end

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    render(conn, :show, post: Blog.get_post!(id))
  end
end

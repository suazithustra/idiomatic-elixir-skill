# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is set only by
  `MyApp.Blog.publish_post/1`, so it is not cast from form params.
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

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill lives in priv/repo/scripts/backfill_published_at.exs.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after migrating: mix run priv/repo/scripts/backfill_published_at.exs
# Schemaless query on purpose, so it does not depend on the Post schema's current shape.
import Ecto.Query

alias MyApp.Repo

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts written by users.
  """

  import Ecto.Query, only: [where: 2, order_by: 2, preload: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns the post with `id`, with its author loaded.

  Raises `Ecto.NoResultsError` when no post has that id, which Phoenix
  turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Lists `user`'s posts, newest first, with the author loaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Sets `published_at` to now and inserts an audit log row. Both happen in
  one transaction, so either both are saved or neither is.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post),
           {:ok, _log} <- record_publish(published) do
        {:ok, published}
      end
    end)
  end

  defp update_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has a changeset/2 and these fields. Adjust to the real schema.
  defp record_publish(post) do
    %Log{}
    |> Log.changeset(%{action: "post_published", resource_type: "post", resource_id: post.id})
    |> Repo.insert()
  end
end

# lib/my_app_web/controllers/post_controller.ex
# Route, in the browser scope of lib/my_app_web/router.ex:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

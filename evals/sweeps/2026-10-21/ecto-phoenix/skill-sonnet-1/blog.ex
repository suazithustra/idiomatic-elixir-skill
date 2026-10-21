# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/backfill_post_published_at.exs
# Run once after the migration: mix run priv/repo/backfill_post_published_at.exs
# Kept out of the migration so schema history does not depend on data logic.
# It uses the table name instead of MyApp.Blog.Post so later schema changes
# cannot break it. Only rows without a value are touched, so it is safe to re-run.
import Ecto.Query

{count, nil} =
  MyApp.Repo.update_all(
    from(post in "posts",
      where: is_nil(post.published_at),
      update: [set: [published_at: post.inserted_at]]
    ),
    []
  )

IO.puts("Set published_at on #{count} posts")

# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is `nil` while the post is a draft. It is set by
  `MyApp.Blog.publish_post/1`, never from form params.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Accounts.User

  @type t :: %__MODULE__{}

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast, so a request cannot set them.
  """
  def changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc false
  def publish_changeset(%__MODULE__{} = post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
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
  Creates a draft post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each post's author loaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([post], desc: post.inserted_at, desc: post.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post with its author. Raises `Ecto.NoResultsError` if it does not
  exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction: if the audit insert fails, the post
  stays unpublished.

  Returns `{:ok, post}`, `{:error, :already_published}`, or
  `{:error, changeset}`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_publish(published) do
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

  # Assumes MyApp.Audit.Log has :action, :resource_type, :resource_id and
  # :user_id fields. Adjust to the real schema.
  defp log_publish(post) do
    Repo.insert(%Log{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    })
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/router.ex (inside the browser scope)
#
#     get "/posts/:id", PostController, :show

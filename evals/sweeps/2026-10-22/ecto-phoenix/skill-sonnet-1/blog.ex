# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is `nil` until the post is published.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast, so a request cannot set them.
  Set `user_id` on the struct before calling this, and publish with
  `MyApp.Blog.publish_post/1`.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query

  alias MyApp.Audit
  alias MyApp.Accounts.User
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded in `post.user`.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([post], desc: post.inserted_at, desc: post.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post by id with its author loaded.

  Raises `Ecto.NoResultsError` if the post does not exist; Phoenix renders that as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records the action in the audit log.

  The post update and the audit log insert happen in one transaction: if either
  fails, neither is saved.

  Returns `{:ok, post}`, `{:error, :already_published}`, or `{:error, changeset}`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- Repo.update(Post.publish_changeset(post, DateTime.utc_now())),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  # Assumes MyApp.Audit.Log has `action`, `description` and `user_id` fields and a
  # `changeset/2` that casts them; adjust to the real schema.
  defp insert_publish_log(%Post{} = post) do
    %Audit.Log{}
    |> Audit.Log.changeset(%{
      action: "post.published",
      description: "Published post #{post.id} (#{post.title})",
      user_id: post.user_id
    })
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime_usec
    end
  end
end

# File: priv/repo/backfill_post_published_at.exs
# Run once after the migration: mix run priv/repo/backfill_post_published_at.exs
# Safe to run again; it only touches posts whose published_at is still nil.
import Ecto.Query

{count, nil} =
  MyApp.Repo.update_all(
    from(post in "posts",
      where: is_nil(post.published_at),
      update: [set: [published_at: post.inserted_at]]
    ),
    []
  )

IO.puts("Set published_at on #{count} existing posts")

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
#   get "/posts/:id", PostController, :show

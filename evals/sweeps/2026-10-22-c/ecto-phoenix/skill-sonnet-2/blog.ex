# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is `nil` until the post is published with
  `MyApp.Blog.publish_post/1`.
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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast: the owner is set by the context
  and `published_at` only changes through `MyApp.Blog.publish_post/1`.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and the actions on them.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their author loaded.
  """
  def list_user_posts(%User{} = user) do
    query =
      from p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Gets a post with its author loaded. Raises `Ecto.NoResultsError` if there is
  no post with `id`, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction, so if either fails neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_published(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Ecto.Changeset.change(published_at: published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has an `action` string and a `changeset/2`
  # that casts it; adjust the attributes to the real schema.
  defp log_published(post) do
    attrs = %{action: "post.published", description: "Published post #{post.id}"}

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_posts_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_posts_published_at.exs
# It queries the table by name so it does not depend on the Post schema.
import Ecto.Query, only: [from: 2]

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(backfill, [])

IO.puts("Set published_at on #{count} existing posts")

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

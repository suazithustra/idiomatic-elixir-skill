# File: priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/scripts/backfill_post_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_post_published_at.exs
# Existing posts count as published at the moment they were inserted. It queries
# the table by name so it does not depend on the current Post schema.
import Ecto.Query, only: [from: 2]

alias MyApp.Repo

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = Repo.update_all(backfill, [])

IO.puts("Backfilled published_at on #{count} posts")

# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post with no `published_at` is a draft.
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

  `published_at` and `user_id` are not cast, so a request cannot set them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Builds a changeset that marks the post as published at `published_at`.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
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
  Lists the posts of `user`, newest first, with the author loaded.
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
  Gets a post with its author. Raises `Ecto.NoResultsError` if there is none,
  which Phoenix renders as a 404.
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
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post, published_at),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  defp update_published_at(post, published_at) do
    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has :action and :description fields and a
  # changeset/2 that casts them.
  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      description: "Post #{post.id} (#{inspect(post.title)}) published by user #{post.user_id}"
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
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

# File: lib/my_app_web/router.ex (inside the existing browser scope)
#
#     get "/posts/:id", PostController, :show

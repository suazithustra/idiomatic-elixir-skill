# ---- priv/repo/migrations/20261022120000_add_published_at_to_posts.exs ----
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---- priv/repo/scripts/backfill_published_at.exs ----
# Data backfill kept out of the migration. Run once after migrating, with
#
#     mix run priv/repo/scripts/backfill_published_at.exs
#
# It is idempotent: only posts without a published_at are touched. It uses the
# bare "posts" table instead of MyApp.Blog.Post so later schema changes cannot
# break it.
import Ecto.Query, only: [from: 2]

alias MyApp.Repo

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = Repo.update_all(query, [])
IO.puts("Backfilled published_at on #{count} posts")

# ---- lib/my_app/blog/post.ex ----
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is not castable from form params; it is set by
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

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# ---- lib/my_app/blog.ex ----
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:ok, post}`, or `{:error, changeset}` when the params are invalid.
  """
  @spec create_post(User.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded as `post.user`.
  """
  @spec list_user_posts(User.t()) :: [Post.t()]
  def list_user_posts(%User{} = user) do
    query =
      from p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Gets a post by id.

  Raises `Ecto.NoResultsError` when there is none, which Phoenix renders as a 404.
  """
  @spec get_post!(term()) :: Post.t()
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Publishes `post` and records the action in the audit log.

  The two writes run in one transaction: if either fails, neither is kept.
  """
  @spec publish_post(Post.t()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
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

  # Assumes MyApp.Audit.Log has `action` and `description` string fields and a
  # `changeset/2` that casts them.
  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      description: "Post #{post.id} published by user #{post.user_id}"
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ---- lib/my_app_web/controllers/post_controller.ex ----
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

# ---- lib/my_app_web/router.ex (inside the browser scope) ----
#
#     get "/posts/:id", PostController, :show

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
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
  Builds a changeset for the fields a user may edit.

  `user_id` and `published_at` are set by the code, never cast from params.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
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

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context: creating, listing, reading, and publishing posts.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  @spec create_post(User.t(), map()) :: {:ok, Post.t()} | {:error, Changeset.t()}
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first, with each post's `user` preloaded
  so the page can show the author's name without a query per post.
  """
  @spec list_user_posts(User.t()) :: [Post.t()]
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    # id breaks ties between posts inserted in the same second
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id. Raises `Ecto.NoResultsError` if it does not exist.
  """
  @spec get_post!(term()) :: Post.t()
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Publishes `post` and records the action in the audit log, in one
  transaction: if either write fails, neither is kept.

  Returns `{:ok, post}` or `{:error, changeset}` from the failing write.
  """
  @spec publish_post(Post.t()) :: {:ok, Post.t()} | {:error, Changeset.t()}
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _log} <- log_publication(published) do
        {:ok, published}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Field names follow the existing audit_logs table; adjust if they differ.
  defp log_publication(post) do
    %Log{}
    |> Changeset.change(
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    )
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
#
# Sets published_at to inserted_at for posts that existed before drafts did.
# Run with `mix run priv/repo/scripts/backfill_posts_published_at.exs` after
# the migration and before deploying the code that creates unpublished posts;
# otherwise new drafts would be published by this script too. It queries the
# "posts" table directly so it does not depend on the Post schema as it changes.
import Ecto.Query

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _rows} = MyApp.Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Phoenix turns the Ecto.NoResultsError from get_post!/1 into a 404.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

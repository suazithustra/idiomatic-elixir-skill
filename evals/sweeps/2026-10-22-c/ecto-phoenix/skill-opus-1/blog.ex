# lib/my_app/blog/post.ex
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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for the fields an author may edit.

  `user_id` and `published_at` are set by the code, never cast from params.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Builds a changeset that marks the post as published at `published_at`.
  """
  @spec publish_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context: creating, listing, and publishing posts.
  """
  import Ecto.Query, only: [where: 2, order_by: 2, preload: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post authored by `user` from form params.
  """
  @spec create_post(User.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each post's author preloaded.
  """
  @spec list_user_posts(User.t()) :: [Post.t()]
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id, with its author preloaded.

  Raises `Ecto.NoResultsError` if there is no such post.
  """
  @spec get_post!(term()) :: Post.t()
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` now and records the action in the audit log.

  Both writes run in one transaction: if either fails, neither is kept.
  """
  @spec publish_post(Post.t()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
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

  # Assumes MyApp.Audit.Log exposes changeset/2 over action, user_id, and metadata;
  # adjust the attributes to the existing audit_logs columns.
  defp log_publication(post) do
    log_attrs = %{
      action: "post.published",
      user_id: post.user_id,
      metadata: %{post_id: post.id, published_at: post.published_at}
    }

    %Log{}
    |> Log.changeset(log_attrs)
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
# Run once, right after the migration and before any draft is created:
#
#     mix run priv/repo/scripts/backfill_posts_published_at.exs
#
# It queries the "posts" table by name rather than through MyApp.Blog.Post,
# so later changes to the schema module cannot break it.
import Ecto.Query, only: [from: 2]

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(backfill, [])
IO.puts("Set published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# Each part below is a separate file in the project. The file each part would
# live in is named on the comment line above it.
#
# Assumes: the posts table already has title, body, user_id and inserted_at
# columns; the User schema has a name field; MyApp.Audit.Log has an `action`
# and a `details` string field and a `changeset/2` function.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
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

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  # published_at is not cast: a form cannot set it, only publish_post/1 does.
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [where: 3, order_by: 3, preload: 2]

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
  Lists the posts of `user`, newest first, with their author loaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches one post with its author loaded. Raises `Ecto.NoResultsError` when
  the post does not exist, which Phoenix turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records the action in the audit log.

  The post update and the audit insert run in one transaction. If either
  fails, both are rolled back and the post stays unpublished.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn -> publish_and_log(post) end)
  end

  defp publish_and_log(post) do
    changeset = Post.publish_changeset(post, DateTime.utc_now(:second))

    with {:ok, published} <- Repo.update(changeset),
         {:ok, _log} <- insert_audit_log(published) do
      {:ok, published}
    end
  end

  defp insert_audit_log(post) do
    attrs = %{
      action: "post.published",
      details: "published post #{post.id}: #{post.title}"
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts get published_at = inserted_at, as requested. The SQL uses
    # no application schema module, so later changes to MyApp.Blog.Post cannot
    # break it. Rolling back needs no reverse SQL: dropping the column removes
    # the values.
    execute("UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL", "")
  end
end

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

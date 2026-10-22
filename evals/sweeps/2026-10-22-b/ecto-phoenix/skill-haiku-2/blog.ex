# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    timestamps(type: :utc_datetime)
  end

  # user_id is not cast: the context sets it, so a request cannot choose the owner.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts written by users.
  """

  import Ecto.Query, warn: false

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form `params`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts newest first. Each post has its author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  The post update and the audit insert run in one transaction, so either both
  are committed or neither is.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _log} <- insert_audit_log(published) do
        {:ok, published}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  # The field names below are assumptions; match them to the MyApp.Audit.Log schema.
  defp insert_audit_log(post) do
    %Log{}
    |> Log.changeset(%{
      action: "post.published",
      subject_type: "Post",
      subject_id: post.id,
      user_id: post.user_id
    })
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Raw SQL, not the Post schema: the schema can change after this migration has run.
    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# lib/my_app_web/controllers/post_controller.ex
# Route in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

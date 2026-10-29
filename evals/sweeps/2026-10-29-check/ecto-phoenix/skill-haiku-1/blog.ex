# Each part below names the file it would live in. Not compiled: Phoenix and Ecto are not installed.
# Assumed, to check against the project:
#   - the posts table already exists with title, body, user_id and timestamps
#   - MyApp.Audit.Log has a changeset/2 and fields action, resource_type, resource_id, user_id
#   - the user's posts table uses utc_datetime timestamps

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

  @doc """
  Casts and validates the fields a user may set. `user_id` is set by the
  context, not taken from params.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at` on a post. Takes the time as an argument so the caller
  can use the same value for the audit row.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Creates, lists, shows and publishes blog posts.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
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
  Lists the posts of `user`, newest first, with the author preloaded.
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
  Gets a post by id with its author preloaded. Raises `Ecto.NoResultsError`
  when the post does not exist.
  """
  def get_post!(id) do
    post = Repo.get!(Post, id)
    Repo.preload(post, :user)
  end

  @doc """
  Publishes a post: sets `published_at` to now and inserts an audit row.
  Both happen in one transaction, so either both are saved or neither is.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now(:second)

    multi =
      Multi.new()
      |> Multi.update(:post, Post.publish_changeset(post, published_at))
      |> Multi.insert(:audit_log, &publish_audit_changeset/1)

    case Repo.transaction(multi) do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp publish_audit_changeset(%{post: post}) do
    attrs = %{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    }

    Log.changeset(%Log{}, attrs)
  end
end

# priv/repo/migrations/20261029000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Plain SQL, not application schema modules, so the migration does not
    # depend on how the schema module changes later.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# lib/my_app_web/controllers/post_controller.ex
# Route, in lib/my_app_web/router.ex inside the browser scope:
#   get "/posts/:id", PostController, :show
# Needs a show template in lib/my_app_web/controllers/post_html.ex (PostHTML).
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

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

  @doc """
  Changeset for user-submitted form params.

  `user_id` and `published_at` are deliberately not cast: the owner is set by
  the context from the authenticated user, and publishing goes through
  `publish_changeset/2`.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, %DateTime{} = now) do
    change(post, published_at: now)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first, with `:user` preloaded so the author's
  name can be rendered without a query per post.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a single post with its author preloaded.

  Raises `Ecto.NoResultsError` (rendered as a 404) if the post does not exist.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records an audit log entry, atomically.

  Returns `{:ok, post}` or `{:error, reason}`; if either write fails, neither
  is persisted.
  """
  def publish_post(%Post{published_at: nil} = post) do
    now = DateTime.utc_now(:second)

    Repo.transact(fn ->
      with {:ok, post} <- post |> Post.publish_changeset(now) |> Repo.update(),
           {:ok, _log} <- Repo.insert(audit_log_for_publish(post)) do
        {:ok, post}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  # Field names assume the existing audit_logs schema; adjust to match
  # MyApp.Audit.Log (or call its changeset function if it defines one).
  defp audit_log_for_publish(%Post{} = post) do
    %Log{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    }
  end
end

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Plain SQL rather than the Post schema, so this migration keeps working
  # even after the schema changes. For a very large posts table, move the
  # UPDATE into a separate batched migration (@disable_ddl_transaction) to
  # avoid holding row locks across the whole table in one transaction.
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
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

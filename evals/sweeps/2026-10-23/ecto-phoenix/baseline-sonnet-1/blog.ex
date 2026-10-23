# File: priv/repo/migrations/20261023000000_create_posts.exs
# Only needed if the posts table does not exist yet.
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :body, :text, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:posts, [:user_id, :inserted_at])
  end
end

# File: priv/repo/migrations/20261023000100_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # The column must exist before the UPDATE runs.
    flush()

    execute "UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# File: lib/my_app/blog/post.ex
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

  # published_at and user_id are not cast from form params: publishing goes
  # through Blog.publish_post/1 and the owner is set by Blog.create_post/2.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:user_id)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc "Blog posts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists one user's posts, newest first, with the author preloaded so a page
  can show `post.user.name` without one query per post.
  """
  def list_posts_for_user(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]
    )
  end

  @doc """
  Gets a post by id with its author. Raises `Ecto.NoResultsError` if missing,
  which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row in one transaction.
  If either step fails, neither is saved.

  Assumes MyApp.Audit.Log has the fields `action`, `resource_type`,
  `resource_id` and `user_id`. Adjust to the real schema.
  """
  def publish_post(%Post{published_at: nil} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.update(:post, Ecto.Changeset.change(post, published_at: now))
    |> Multi.insert(:audit_log, fn %{post: published} ->
      Ecto.Changeset.change(%Audit.Log{}, %{
        action: "post.published",
        resource_type: "post",
        resource_id: published.id,
        user_id: published.user_id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def publish_post(%Post{}), do: {:error, :already_published}
end

# File: lib/my_app_web/router.ex (inside the :browser scope)
#
#     get "/posts/:id", PostController, :show

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/controllers/post_html.ex
# The template goes in lib/my_app_web/controllers/post_html/show.html.heex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

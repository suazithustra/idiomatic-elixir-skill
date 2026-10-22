# One file holding every part of the blog feature. Each part is preceded by
# the path it would live at in a Phoenix app.
#
# The backfill is a separate script, not part of the migration: the migration
# only changes the schema. Run the migration first, then the script once.
#
# Assumes MyApp.Audit.Log has `action`, `resource_type`, and `resource_id`
# fields and a `changeset/2`. Adjust insert_audit_log/1 if the schema differs.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is set by `publish_changeset/1`, not by `changeset/2`, so
  form params cannot publish a post on their own.
  """

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

  def publish_changeset(%__MODULE__{} = post) do
    change(post, published_at: DateTime.utc_now(:second))
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Creates, lists, and publishes blog posts.
  """

  import Ecto.Query, only: [where: 3, order_by: 3, preload: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where([p], p.user_id == ^user.id)
    # Posts inserted in the same second are ordered by id, so the order is stable.
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises if it does not exist.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.

  Both writes run in one transaction, so either both happen or neither does.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- Repo.update(Post.publish_changeset(post)),
           {:ok, _audit_log} <- insert_audit_log(published) do
        {:ok, published}
      end
    end)
  end

  defp insert_audit_log(%Post{} = post) do
    attrs = %{
      action: "post.published",
      resource_type: "Post",
      resource_id: post.id
    }

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

# priv/repo/scripts/backfill_post_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_post_published_at.exs
import Ecto.Query, only: [where: 3, update: 3]

alias MyApp.Blog.Post
alias MyApp.Repo

{count, _} =
  Post
  |> where([p], is_nil(p.published_at))
  |> update([p], set: [published_at: p.inserted_at])
  |> Repo.update_all([])

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

# Assumptions: the posts table already exists with title, body, and user_id columns;
# MyApp.Audit.Log has a changeset/2 and the fields action, description, and user_id;
# MyApp.Accounts.User has a name field.
#
# The backfill is kept out of the migration on purpose. The skill's Ecto/Phoenix
# reference says migrations should only change schema, so the backfill is a script
# that runs once after `mix ecto.migrate`. The migration only adds the column.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user.
  """

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
  Casts and validates form params. `published_at` is not cast, so a form cannot
  publish a post on its own; only `publish_changeset/1` sets it.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at` to the current time, truncated to the second to match the column.
  """
  def publish_changeset(%__MODULE__{} = post) do
    change(post, published_at: DateTime.utc_now(:second))
  end
end

# priv/repo/migrations/20261023120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# The `is_nil` filter makes a second run a no-op.
import Ecto.Query, only: [from: 2]

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _} = MyApp.Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, reading, and publishing them.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Returns the user's posts, newest first, with the author preloaded for display.
  """
  def list_user_posts(%User{} = user) do
    query =
      from p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]

    Repo.all(query)
  end

  @doc """
  Returns the post with its author preloaded. Raises `Ecto.NoResultsError` when missing,
  which Phoenix turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and inserts an audit log row. Both happen or neither does.

  Returns `{:ok, post}` or `{:error, reason}`.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- post |> Post.publish_changeset() |> Repo.update(),
           {:ok, _log} <- record_audit(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp record_audit(post, action) do
    attrs = %{
      action: action,
      description: "published post #{post.id}: #{post.title}",
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
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

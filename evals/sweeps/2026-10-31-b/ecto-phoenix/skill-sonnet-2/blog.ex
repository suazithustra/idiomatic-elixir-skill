# priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is `nil` until the post is published.
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

  @doc """
  Casts and validates form params. `user_id` and `published_at` are set by
  the context, so they are not castable.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at` to the given time.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [where: 2, order_by: 2, preload: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, each with its `:user` loaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post with its `:user` loaded. Raises `Ecto.NoResultsError` when it
  does not exist, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a post and records it in the audit log in one transaction, so
  either both happen or neither does.

  Returns `{:ok, post}`, `{:error, :already_published}` or `{:error, changeset}`.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp update_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has the fields `action` and `description`;
  # adjust to the real schema.
  defp insert_publish_log(post) do
    attrs = [action: "post.published", description: "Published post #{post.id}"]

    %Log{}
    |> Ecto.Changeset.change(attrs)
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

# lib/mix/tasks/my_app.backfill_published_at.ex
#
# Run once, after the migration: mix my_app.backfill_published_at
# It sets published_at to inserted_at on every post that has none, so run it
# before new unpublished posts exist. It is kept out of the migration so the
# schema change carries no data logic, and it queries the "posts" table by
# name so it does not depend on the Post schema.
defmodule Mix.Tasks.MyApp.BackfillPublishedAt do
  @shortdoc "Sets published_at to inserted_at on existing posts"

  @moduledoc """
  Sets `published_at` to `inserted_at` on every post that has no `published_at`.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias MyApp.Repo

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    query =
      from p in "posts",
        where: is_nil(p.published_at),
        update: [set: [published_at: p.inserted_at]]

    {count, nil} = Repo.update_all(query, [])
    Mix.shell().info("Backfilled published_at on #{count} posts")
  end
end

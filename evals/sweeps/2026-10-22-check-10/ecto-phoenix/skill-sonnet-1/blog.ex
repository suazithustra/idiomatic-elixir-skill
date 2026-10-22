# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is `nil` until the post is published.
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

    timestamps()
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast: the context sets them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their authors.
  """

  import Ecto.Query, only: [from: 2]

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
  Lists the posts of `user`, newest first, with each author loaded.
  """
  def list_posts(%User{} = user) do
    query =
      from p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Gets a post by id, with its author loaded. Raises `Ecto.NoResultsError` if missing.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction, so either both are saved or neither is.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_published(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp log_published(post) do
    # Adjust the attrs to the fields of MyApp.Audit.Log.
    attrs = %{
      action: "post.published",
      description: "Published post #{post.id} (#{post.title})"
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

# lib/my_app/release_tasks/backfill_published_at.ex
# Data backfill, kept out of the migration. Run after migrating:
#   mix backfill_published_at
# (or call MyApp.ReleaseTasks.BackfillPublishedAt.run/0 from a release command).
defmodule MyApp.ReleaseTasks.BackfillPublishedAt do
  @moduledoc """
  Sets `published_at` to `inserted_at` for posts that existed before the column was added.

  Queries the table by name, so it does not depend on the `Post` schema.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Repo

  @doc """
  Returns the number of posts updated.
  """
  def run do
    query =
      from p in "posts",
        where: is_nil(p.published_at),
        update: [set: [published_at: p.inserted_at]]

    {count, nil} = Repo.update_all(query, [])
    count
  end
end

# lib/mix/tasks/backfill_published_at.ex
defmodule Mix.Tasks.BackfillPublishedAt do
  @shortdoc "Sets published_at to inserted_at for existing posts"
  @moduledoc @shortdoc

  use Mix.Task

  alias MyApp.ReleaseTasks.BackfillPublishedAt

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    count = BackfillPublishedAt.run()
    Mix.shell().info("Updated #{count} posts")
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

# lib/my_app_web/router.ex (inside the browser scope)
#   get "/posts/:id", PostController, :show

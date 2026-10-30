# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post with no `published_at` is a draft.
  """

  use Ecto.Schema

  import Ecto.Changeset, only: [assoc_constraint: 2, cast: 3, change: 2, validate_required: 2]

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc """
  Casts and validates form params. `user_id` is not cast: the context sets it.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Builds the changeset that marks a post as published at `published_at`.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a draft post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author loaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author loaded. Raises `Ecto.NoResultsError`
  (a 404 response in Phoenix) when there is none.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes a draft and records the action in the audit log.

  The update and the log insert run in one transaction: both happen or
  neither does. Returns `{:error, :already_published}` for a published post.
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

  # Assumes MyApp.Audit.Log has `action` and `description` fields and a
  # `changeset/2`; adjust to the real schema.
  defp insert_publish_log(post) do
    attrs = %{action: "post.published", description: "Post #{post.id} published"}

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
  end
end

# lib/mix/tasks/my_app.backfill_published_at.ex
defmodule Mix.Tasks.MyApp.BackfillPublishedAt do
  @shortdoc "Sets published_at to inserted_at on posts that have none"

  @moduledoc """
  Run once after the `add_published_at_to_posts` migration:

      mix my_app.backfill_published_at

  Uses a schemaless query so it does not depend on the `Post` schema.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias MyApp.Repo

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    query =
      from post in "posts",
        where: is_nil(post.published_at),
        update: [set: [published_at: post.inserted_at]]

    {count, nil} = Repo.update_all(query, [])
    Mix.shell().info("Backfilled #{count} posts")
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

# lib/my_app_web/router.ex (inside the :browser scope)
#   get "/posts/:id", PostController, :show

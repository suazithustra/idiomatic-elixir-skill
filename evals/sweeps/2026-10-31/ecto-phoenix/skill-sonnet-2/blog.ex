# Assumptions: the posts table and its user_id column already exist, timestamps are
# :utc_datetime, and MyApp.Audit.Log has an `action` and a `description` field and a
# `changeset/2` function.

# priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# lib/mix/tasks/my_app.backfill_post_published_at.ex
defmodule Mix.Tasks.MyApp.BackfillPostPublishedAt do
  @shortdoc "Sets published_at to inserted_at on posts that predate the column"

  @moduledoc """
  Sets `published_at` to `inserted_at` on every post where it is `nil`.

  Run it once, right after the migration and before the code that creates
  unpublished posts is deployed. A later run would publish drafts.

      mix my_app.backfill_post_published_at
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias MyApp.Repo

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    # The table name instead of MyApp.Blog.Post keeps this working when the schema changes.
    unpublished =
      from(post in "posts",
        where: is_nil(post.published_at),
        update: [set: [published_at: post.inserted_at]]
      )

    {count, nil} = Repo.update_all(unpublished, [])
    Mix.shell().info("Set published_at on #{count} posts")
  end
end

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc false

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
  Changeset for form params. `user_id` and `published_at` are set by the
  context, so they are not cast.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

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
  Creates a post for `user` from form params.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each post's author loaded.
  """
  def list_user_posts(%User{} = user) do
    query =
      from(post in Post,
        where: post.user_id == ^user.id,
        order_by: [desc: post.inserted_at, desc: post.id],
        preload: :user
      )

    Repo.all(query)
  end

  @doc """
  Gets a post with its author. Raises `Ecto.NoResultsError` if it does not exist.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.
  Both writes happen or neither does.
  """
  def publish_post(%Post{published_at: %DateTime{}}), do: {:error, :already_published}

  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _log} <- log_published(published) do
        {:ok, published}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp log_published(post) do
    params = %{
      action: "post.published",
      description: "Published post #{post.id} by user #{post.user_id}"
    }

    %Log{}
    |> Log.changeset(params)
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

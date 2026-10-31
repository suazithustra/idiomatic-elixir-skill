# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post owned by a user. A post with no `published_at` is unpublished.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Accounts.User

  @max_title_length 255

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast: the code sets them, so a request cannot.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: @max_title_length)
    |> assoc_constraint(:user)
  end

  @doc """
  Builds the changeset that marks `post` as published at `published_at`.
  """
  def publish_changeset(post, published_at), do: change(post, published_at: published_at)
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context: creates, lists, reads and publishes posts.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

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
  Lists the posts of `user`, newest first, with `:user` preloaded for the author's name.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    # Posts created in the same second tie on inserted_at, so id keeps the order stable.
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets the post with the given id.

  Raises `Ecto.NoResultsError` when there is none, which Phoenix turns into a 404 response.
  """
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Publishes `post` and records the action in the audit log, in one transaction.

  Returns `{:ok, post}`, or `{:error, changeset}` with neither write applied.
  """
  def publish_post(%Post{} = post) do
    changeset = Post.publish_changeset(post, DateTime.utc_now(:second))

    Repo.transact(fn ->
      with {:ok, published_post} <- Repo.update(changeset),
           {:ok, _log} <- Repo.insert(publish_log(published_post)) do
        {:ok, published_post}
      end
    end)
  end

  # The field names are assumed: rename them to match the MyApp.Audit.Log schema.
  defp publish_log(%Post{} = post) do
    %Log{action: "post.published", resource_type: "post", resource_id: post.id}
  end
end

# File: priv/repo/migrations/20261031120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/scripts/backfill_posts_published_at.exs
#
# Sets published_at on existing posts. This is a script and not part of the migration so
# that migrations only change the schema, and it reads the "posts" table and not
# MyApp.Blog.Post so that later schema changes cannot break it.
#
# Run it once, after the migration and before the code that calls create_post/2 goes live:
#
#     mix run priv/repo/scripts/backfill_posts_published_at.exs
#
# From then on a NULL published_at means an unpublished post, so a later run would
# publish all of them.

import Ecto.Query, only: [from: 2]

alias MyApp.Repo

backfill =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = Repo.update_all(backfill, [], timeout: :infinity)
IO.puts("Set published_at on #{count} posts")

# File: lib/my_app_web/router.ex, inside the `scope "/", MyAppWeb` block for browser routes
#
#     get "/posts/:id", PostController, :show

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  @moduledoc """
  Serves blog post pages.
  """

  use MyAppWeb, :controller

  alias MyApp.Blog

  @doc """
  Shows the post with the id from the URL. An unknown id gives a 404 response.
  """
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  @moduledoc false

  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>{@post.title}</.header>
      <p>{@post.body}</p>
    </Layouts.app>
    """
  end
end

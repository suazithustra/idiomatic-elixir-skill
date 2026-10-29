# Blog posts: schema, context, migration, backfill script, and controller.
# Each part starts with a comment naming the file it belongs in.
#
# Assumptions (not checked, no Phoenix or Ecto here to compile against):
#   - The posts table already exists with title, body, and user_id columns.
#   - MyApp.Audit.Log has action, resource_type, resource_id, and user_id
#     fields, and a changeset/2 function.
#   - Phoenix 1.8 generates MyAppWeb.PostHTML with a show/1 template.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user. `published_at` stays `nil` until the post is published.
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

  # user_id and published_at are set by the code, so they are not cast from input.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Creates, reads, and publishes blog posts.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of one user, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    query =
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Fetches one post by id, with the author preloaded. Raises `Ecto.NoResultsError`
  when no post has that id, which Phoenix turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and records the action in the audit log. Both writes happen in
  one transaction, so either both are saved or neither is.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now(:second)
    publish = Ecto.Changeset.change(post, published_at: published_at)

    multi =
      Multi.new()
      |> Multi.update(:post, publish)
      |> Multi.insert(:audit_log, fn %{post: published} ->
        audit_changeset(published, "post.published")
      end)

    case Repo.transaction(multi) do
      {:ok, %{post: published}} -> {:ok, published}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp audit_changeset(post, action) do
    attrs = %{action: action, resource_type: "post", resource_id: post.id, user_id: post.user_id}

    Log.changeset(%Log{}, attrs)
  end
end

# priv/repo/migrations/20261029120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill is in priv/repo/scripts/backfill_published_at.exs
  # so this migration does not depend on application code or change data.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Sets published_at to inserted_at for existing posts. Running it again later would also
# publish any draft that still has no published_at, so run it once.
import Ecto.Query

alias MyApp.Blog.Post
alias MyApp.Repo

query =
  from p in Post,
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
# Route, in the browser scope of lib/my_app_web/router.ex:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

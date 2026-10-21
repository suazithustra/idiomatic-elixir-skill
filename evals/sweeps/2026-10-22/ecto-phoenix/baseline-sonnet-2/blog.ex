# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
# Assumes the posts table already exists (with inserted_at). Existing posts
# are backfilled so they count as published at the time they were created.
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute(
      "UPDATE posts SET published_at = inserted_at",
      "SELECT 1"
    )
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

    timestamps()
  end

  # published_at and user_id are not cast from form params: publishing goes
  # through Blog.publish_post/1 and the owner is set by the context.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc "Blog posts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params."
  def create_post(%User{id: user_id}, attrs) do
    %Post{user_id: user_id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Changeset for rendering the post form."
  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  @doc """
  Lists one user's posts, newest first, with the author loaded in the same
  query (one SQL statement, so the page can show `post.user.name`).
  """
  def list_posts_for_user(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> join(:inner, [p], u in assoc(p, :user))
    |> preload([p, u], user: u)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> Repo.all()
  end

  @doc "Fetches a post with its author. Raises Ecto.NoResultsError if missing."
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes a post and writes an audit log row in one transaction.

  Returns `{:ok, %{post: post, audit_log: log}}`,
  `{:error, :post, :already_published, _}` if the post was already published
  (or does not exist), or `{:error, step, reason, changes}` for any other
  failure. If any step fails, nothing is written.
  """
  def publish_post(%Post{id: post_id, user_id: user_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:post, fn repo, _changes ->
      # The is_nil check is part of the UPDATE, so two concurrent publishes
      # cannot both succeed.
      query =
        from p in Post,
          where: p.id == ^post_id and is_nil(p.published_at),
          select: p

      case repo.update_all(query, set: [published_at: now, updated_at: NaiveDateTime.utc_now(:second)]) do
        {1, [post]} -> {:ok, post}
        {0, _} -> {:error, :already_published}
      end
    end)
    |> Multi.insert(:audit_log, fn %{post: post} ->
      # Assumed fields on MyApp.Audit.Log: :action, :description, :user_id.
      # Adjust to the real schema (and use its changeset if it has one).
      struct!(Log,
        action: "post.published",
        description: "Post #{post.id} (#{inspect(post.title)}) published at #{DateTime.to_iso8601(now)}",
        user_id: user_id
      )
    end)
    |> Repo.transaction()
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # A non-numeric id raises Ecto.Query.CastError, which Phoenix renders as 400;
  # a missing post raises Ecto.NoResultsError, rendered as 404.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/router.ex (inside the browser scope)
#
#   get "/posts/:id", PostController, :show

# File: lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

# File: lib/my_app_web/controllers/post_html/show.html.heex
#
#   <h1>{@post.title}</h1>
#   <p>By {@post.user.name}</p>
#   <div>{@post.body}</div>

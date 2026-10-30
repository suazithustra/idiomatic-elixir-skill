# ---------------------------------------------------------------------------
# priv/repo/migrations/20261031000000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts count as already published, as of the time they were created.
    # New posts get NULL (draft) until Blog.publish_post/1 is called.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
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

  # Used for form params. user_id and published_at are deliberately not cast:
  # the owner is set by the context, and publishing goes through Blog.publish_post/1.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc "Blog posts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a draft post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists a user's posts, newest first, with the author loaded so the page can
  show `post.title` and `post.user.name`. Runs one query.
  """
  def list_user_posts(%User{id: user_id}) do
    from(p in Post,
      join: u in assoc(p, :user),
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [user: u]
    )
    |> Repo.all()
  end

  @doc """
  Gets one post (with its author). Raises `Ecto.NoResultsError` if missing,
  which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and writes an audit log row, in one transaction.

  Returns `{:ok, post}`, `{:error, :already_published}` (also if the post does
  not exist), or `{:error, changeset}` if the audit row is invalid. In every
  error case neither change is saved.

  The update only matches rows where `published_at IS NULL`, so two concurrent
  calls cannot both publish the same post or write two audit rows.
  """
  def publish_post(%Post{id: post_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:post, fn repo, _changes ->
      query = from(p in Post, where: p.id == ^post_id and is_nil(p.published_at), select: p)

      case repo.update_all(query, set: [published_at: now, updated_at: now]) do
        {1, [post]} -> {:ok, post}
        {0, _} -> {:error, :already_published}
      end
    end)
    |> Multi.insert(:log, fn %{post: post} ->
      # ASSUMPTION: Log has :action, :resource_type, :resource_id, :user_id and a
      # changeset/2. Adjust these keys to match the real MyApp.Audit.Log schema.
      Log.changeset(%Log{}, %{
        action: "post.published",
        resource_type: "post",
        resource_id: post.id,
        user_id: post.user_id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_html.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  embed_templates "post_html/*"
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_html/show.html.heex  (template, not Elixir)
# ---------------------------------------------------------------------------
# <Layouts.app flash={@flash}>
#   <h1>{@post.title}</h1>
#   <p>by {@post.user.name}</p>
#   <div>{@post.body}</div>
# </Layouts.app>

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex  (add inside the existing browser scope)
# ---------------------------------------------------------------------------
# get "/posts/:id", PostController, :show

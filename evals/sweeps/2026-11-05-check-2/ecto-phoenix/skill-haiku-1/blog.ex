# Each part below names the file it would live in in a Phoenix 1.8 app.
# Assumptions to check against the real code:
#   - MyApp.Audit.Log has a changeset/2 that accepts :action, :resource, and :resource_id.
#     Rename the keys in log_action/2 if the existing schema uses other names.
#   - MyAppWeb.PostHTML needs a show/1 template (lib/my_app_web/controllers/post_html/show.html.heex).
#   - The route goes inside the browser scope of lib/my_app_web/router.ex.

# ----------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ----------------------------------------------------------------------------

defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user. `published_at` is nil until the post is published.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Accounts.User

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# ----------------------------------------------------------------------------
# priv/repo/migrations/20261105120000_add_published_at_to_posts.exs
# ----------------------------------------------------------------------------

defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Existing posts are treated as published at the moment they were created.
  # The skill's guidance puts large backfills in priv/repo/data_migrations; this
  # is a single UPDATE, kept here because the request asked for it in this migration.
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute("UPDATE posts SET published_at = inserted_at")
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ----------------------------------------------------------------------------
# lib/my_app/blog.ex
# ----------------------------------------------------------------------------

defmodule MyApp.Blog do
  @moduledoc """
  Creates, lists, shows, and publishes blog posts.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form `params`.

  Returns `{:ok, post}` or `{:error, changeset}`. `published_at` is not cast from
  params, so a post starts unpublished until `publish_post/1` runs.
  """
  def create_post(%User{} = user, params) do
    # user_id is set on the struct, not cast, so a request cannot choose the owner.
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first, with the author preloaded for display.
  """
  def list_user_posts(%User{} = user) do
    query =
      from(p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]
      )

    Repo.all(query)
  end

  @doc """
  Fetches one post by id with its author preloaded. Raises `Ecto.NoResultsError`
  when the post does not exist; Phoenix turns that into a 404.
  """
  def get_post!(id) do
    query = from(p in Post, preload: [:user])
    Repo.get!(query, id)
  end

  @doc """
  Sets `published_at` to now and inserts an audit log row. Both happen or neither does.

  Returns `{:ok, post}` or `{:error, reason}`.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now(:second)

    Repo.transact(fn ->
      with {:ok, post} <- set_published_at(post, published_at),
           {:ok, _log} <- log_action(post, "post.published") do
        {:ok, post}
      end
    end)
  end

  defp set_published_at(post, published_at) do
    post
    |> Ecto.Changeset.change(published_at: published_at)
    |> Repo.update()
  end

  defp log_action(post, action) do
    attrs = %{action: action, resource: "post", resource_id: post.id}

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ----------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ----------------------------------------------------------------------------

defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# Route, in lib/my_app_web/router.ex inside the browser scope:
#   get "/posts/:id", PostController, :show

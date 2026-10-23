# Blog posts: schema, context, migration, and controller.
#
# Not compiled: Phoenix and Ecto were not installed. Assumptions about code
# that already exists in the project:
#   - MyApp.Accounts.User has a `name` field.
#   - MyApp.Audit.Log has a `changeset/2` and fields `action`, `resource`,
#     and `resource_id`. Adjust the attrs in `log_action/2` to the real schema.
#   - The posts table was created with `timestamps(type: :utc_datetime)`.
#   - The router has `get "/posts/:id", PostController, :show` in a scope.

# File: lib/my_app/blog/post.ex
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

  # `published_at` is not cast here. Only `publish_changeset/2` sets it, so
  # every published post has a matching audit row.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Writes and reads blog posts.
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
  Returns the posts written by `user`, newest first, with their author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    query =
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at],
        preload: [:user]

    Repo.all(query)
  end

  @doc """
  Returns the post with `id`, with its author preloaded. Raises if it does not exist.
  """
  def get_post!(id) do
    query = from p in Post, preload: [:user]

    Repo.get!(query, id)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.

  Both writes run in one transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    published_at = DateTime.utc_now(:second)

    Repo.transact(fn ->
      with {:ok, published} <- Repo.update(Post.publish_changeset(post, published_at)),
           {:ok, _log} <- log_action(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp log_action(post, action) do
    attrs = %{action: action, resource: "post", resource_id: post.id}

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # The backfill is raw SQL, not a schema module, so it does not depend on
  # the Post schema as it is today. The skill's guidance is to move data
  # changes like this into a separate script; this follows the request to do
  # it in the migration. Move the `execute` into a script if that is preferred.
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # A missing post raises Ecto.NoResultsError, which Phoenix turns into a 404.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

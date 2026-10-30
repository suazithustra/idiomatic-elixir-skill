# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post. `published_at` is `nil` until the post is published.
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
  Casts the fields a form may set. `user_id` and `published_at` are set by code only, so a
  request cannot assign a post to another user or publish it.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at` to the current time.
  """
  def publish_changeset(post) do
    change(post, published_at: DateTime.utc_now(:second))
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Creating, listing and publishing blog posts.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:ok, post}`, or `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with `:user` preloaded so that a page can read
  `post.user.name` without a query per post.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    # inserted_at has one-second precision, so id orders posts created in the same second.
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id.

  Raises `Ecto.NoResultsError` when there is no such post, which Phoenix turns into a 404.
  """
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Sets `published_at` to now and records the action in the audit log, in one transaction.

  Returns `{:ok, post}`, or `{:error, changeset}` with neither write applied.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published_post} <- Repo.update(Post.publish_changeset(post)),
           {:ok, _audit_log} <- insert_audit_log(published_post) do
        {:ok, published_post}
      end
    end)
  end

  # MyApp.Audit.Log was not available when this was written. This assumes the usual
  # changeset/2, casting these four fields; adjust the names to match the real schema.
  defp insert_audit_log(%Post{} = post) do
    attrs = %{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261031120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_post_published_at.exs
#
# Sets published_at to inserted_at on the posts that existed before the column did. The data
# change stays out of the migration, and the SQL names tables rather than the Post schema, so
# it keeps working when the schema changes.
#
# Once the new code is live, a NULL published_at means a draft. Reading the time the migration
# ran from schema_migrations limits the update to older posts, so a late run or a second run
# cannot publish drafts.
#
# Run it after the migration:
#
#     mix run priv/repo/scripts/backfill_post_published_at.exs
#
# On a release, which has no Mix:
#
#     bin/my_app rpc 'Code.eval_file(
#       Application.app_dir(:my_app, "priv/repo/scripts/backfill_post_published_at.exs"))'
backfill_sql = """
UPDATE posts
SET published_at = inserted_at
WHERE published_at IS NULL
  AND inserted_at <= (SELECT inserted_at FROM schema_migrations WHERE version = 20261031120000)
"""

%{num_rows: count} = MyApp.Repo.query!(backfill_sql)
IO.puts("Set published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
#
# lib/my_app_web/router.ex needs this line in the browser scope:
#
#     get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # This also shows drafts: the request set no rule for hiding them.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>{@post.title}</h1>
      <div class="whitespace-pre-wrap">{@post.body}</div>
    </Layouts.app>
    """
  end
end

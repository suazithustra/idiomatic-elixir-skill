# Each part below names the file it would live in. Split it into those files.
# Not compiled here: Phoenix and Ecto are not installed.
# Assumptions: default integer ids; MyApp.Audit.Log has a changeset/2 function
# with action, subject, and subject_id fields (adjust the attrs to the real schema).

# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
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

  # published_at is left out of cast/3 so form input cannot set it.
  # publish_changeset/1 sets it instead.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 200)
  end

  def publish_changeset(post) do
    change(post, published_at: DateTime.utc_now(:second))
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, attrs) do
    # user_id is set on the struct, not cast, so params cannot change the author.
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where([p], p.user_id == ^user.id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Sets `published_at` to now and writes an audit log row.

  Both writes run in one transaction: if either fails, neither is kept.
  Returns `{:ok, post}` or `{:error, reason}`.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, post} <- post |> Post.publish_changeset() |> Repo.update(),
           {:ok, _log} <- insert_publish_log(post) do
        {:ok, post}
      end
    end)
  end

  @doc """
  Gets a post by id with its author preloaded. Raises `Ecto.NoResultsError` if missing.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  defp insert_publish_log(%Post{} = post) do
    %Log{}
    |> Log.changeset(%{
      action: "post.published",
      subject: "post",
      subject_id: to_string(post.id)
    })
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261021000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill lives in priv/repo/scripts/ (see below),
  # so the migration does not depend on application data or schema modules.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/scripts/backfill_post_published_at.exs
# Run once with: mix run priv/repo/scripts/backfill_post_published_at.exs
# Uses a schemaless query so it does not depend on the Post schema's current shape.
# The is_nil filter makes a rerun a no-op.
import Ecto.Query

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _} = MyApp.Repo.update_all(query, [])
IO.puts("Backfilled published_at on #{count} posts")

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  # Needs a route in lib/my_app_web/router.ex: get "/posts/:id", PostController, :show
  # A missing id raises Ecto.NoResultsError, which Phoenix turns into a 404.
  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

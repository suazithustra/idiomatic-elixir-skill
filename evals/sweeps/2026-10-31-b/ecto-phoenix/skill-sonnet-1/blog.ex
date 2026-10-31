# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.
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

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast, so a request cannot set them.
  Set `user_id` on the struct before calling this, and publish through
  `MyApp.Blog.publish_post/1`.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261031120000_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# ---------------------------------------------------------------------------
# File: priv/repo/backfill_posts_published_at.exs
#
# Run once after the migration: mix run priv/repo/backfill_posts_published_at.exs
# It is kept out of the migration so schema history does not carry data logic.
# It queries the "posts" table by name, so it does not depend on the Post
# schema as it looks today. Rows that already have a value are left alone, so
# running it twice is safe.
# ---------------------------------------------------------------------------
import Ecto.Query, only: [from: 2]

alias MyApp.Repo

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _rows} = Repo.update_all(query, [])
IO.puts("Set published_at on #{count} posts")

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publication.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  Returns `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each post's author loaded.
  """
  def list_posts_for_user(%User{} = user) do
    query =
      from p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Gets a post with its author. Raises `Ecto.NoResultsError` when it does not exist.
  """
  def get_post!(id) do
    query = from p in Post, preload: :user

    Repo.get!(query, id)
  end

  @doc """
  Publishes a post: sets `published_at` to now and records an audit log entry.

  Both writes happen in one transaction, so if either fails neither is kept.
  Returns `{:error, :already_published}` for a post that has a `published_at`.
  """
  def publish_post(%Post{published_at: %DateTime{}}), do: {:error, :already_published}

  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has `action`, `user_id` and `metadata` fields and a
  # `changeset/2` that casts them; adjust to the real schema.
  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      user_id: post.user_id,
      metadata: %{post_id: post.id, title: post.title}
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
# (route: get "/posts/:id", PostController, :show)
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

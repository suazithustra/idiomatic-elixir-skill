# ---------------------------------------------------------------------------
# priv/repo/migrations/20261023120000_add_published_at_to_posts.exs
# Schema change only. Existing rows are backfilled by the script below, run
# once after this migration, so no schema module or data logic lives here.
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
# priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Uses the table name instead of MyApp.Blog.Post so it keeps working if the
# schema changes later. Rerunning it is safe: it only touches unset rows.
# ---------------------------------------------------------------------------
import Ecto.Query, only: [from: 2]

alias MyApp.Repo

query = from(p in "posts", where: is_nil(p.published_at), update: [set: [published_at: p.inserted_at]])

{count, nil} = Repo.update_all(query, [])
IO.puts("Set published_at on #{count} existing posts")

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
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
  Casts form params. `user_id` and `published_at` are not castable: the
  context sets the author, and `publish_changeset/2` sets the publish time.
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

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params (`"title"`, `"body"`).
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each author loaded.
  """
  def list_user_posts(%User{} = user) do
    query =
      from p in Post,
        join: author in assoc(p, :user),
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: author]

    Repo.all(query)
  end

  @doc """
  Gets one post with its author. Raises `Ecto.NoResultsError` if missing,
  which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and records the action in the audit log.
  Both writes happen in one transaction, or neither does.
  """
  def publish_post(%Post{published_at: nil} = post) do
    Repo.transact(fn ->
      published_at = DateTime.utc_now(:second)

      with {:ok, published} <- update_published_at(post, published_at),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  def publish_post(%Post{}), do: {:error, :already_published}

  defp update_published_at(post, published_at) do
    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has :action, :user_id and :details fields and a
  # changeset/2 that casts them; adjust to the real schema.
  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      user_id: post.user_id,
      details: %{post_id: post.id, title: post.title}
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex (add inside the browser scope)
# ---------------------------------------------------------------------------
#     get "/posts/:id", PostController, :show

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

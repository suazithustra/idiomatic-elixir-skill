# Blog posts for a Phoenix 1.8 + Ecto + PostgreSQL app. Not compiled (no Phoenix or Ecto installed here).
#
# Each part is labeled with the file it belongs in. Split the parts into those files as shown.
#
# Assumptions to check against the real project:
#   - MyApp.Audit.Log has a changeset/2 and fields :action, :entity, :entity_id, :user_id.
#   - Ecto is 3.13 or later (Repo.transact/2).
#   - Phoenix 1.8 generator defaults: timestamps are :utc_datetime, so the
#     published_at column and inserted_at share the same type. The backfill copies
#     one column into the other with no conversion.
#
# Deviation from the request: the backfill (published_at = inserted_at for existing
# posts) is in a separate script, not in the migration. The project's
# ecto-phoenix guidance says data changes belong outside schema migrations.
# The migration only adds the column. Run the script once, right after the migration.

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is nil until the post is published.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, MyApp.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts the fields a user may enter. `user_id` and `published_at` are set in code,
  never from request params.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body, :user_id])
    |> validate_length(:title, max: 200)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Sets `published_at` to the current time, truncated to seconds to match the column.
  """
  def publish_changeset(post) do
    change(post, published_at: DateTime.utc_now(:second))
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/audit/log.ex
# ---------------------------------------------------------------------------
# Already exists in the project. Shown here only for the assumed interface;
# do not overwrite the real file. Adjust field names in MyApp.Blog.record_audit/2 to match.

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, reading, and publishing them.
  """

  import Ecto.Query, warn: false

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.

  ## Examples

      iex> create_post(user, %{"title" => "Hi", "body" => "Hello"})
      {:ok, %Post{}}

      iex> create_post(user, %{"title" => ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets one post by id, with the author preloaded. Raises `Ecto.NoResultsError` if missing.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` and records the action in the audit log. Both writes happen in one
  transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, post} <- post |> Post.publish_changeset() |> Repo.update(),
           {:ok, _log} <- record_audit(post, "post.published") do
        {:ok, post}
      end
    end)
  end

  defp record_audit(post, action) do
    %Log{}
    |> Log.changeset(%{
      action: action,
      entity: "post",
      entity_id: post.id,
      user_id: post.user_id
    })
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
# Route, in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
#
# The render call needs MyAppWeb.PostHTML with a show/1 function or show.html.heex.
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
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
# priv/repo/scripts/backfill_post_published_at.exs
# Run once, right after the migration, with: mix run priv/repo/scripts/backfill_post_published_at.exs
# Running it later would also publish drafts created since the migration.
# ---------------------------------------------------------------------------
import Ecto.Query

alias MyApp.Blog.Post
alias MyApp.Repo

{count, _} =
  Post
  |> where([p], is_nil(p.published_at))
  |> update([p], set: [published_at: p.inserted_at])
  |> Repo.update_all([])

IO.puts("Backfilled published_at on #{count} posts")

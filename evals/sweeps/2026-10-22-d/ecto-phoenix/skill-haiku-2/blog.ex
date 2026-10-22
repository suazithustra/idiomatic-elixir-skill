# Blog posts: context, schema, migration, backfill script, and controller.
#
# Assumptions (not in the request, check against the project):
#   * The posts table already exists with user_id, title, body, and timestamps().
#   * MyApp.Audit.Log has a changeset/2 that casts :action, :subject_type,
#     :subject_id, and :user_id. Adjust the attrs in insert_audit_log/2 to its real fields.
#   * MyApp.Accounts.User has a name field; the page reads the author through the :user association.

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

    timestamps()
  end

  # published_at is not cast: it is set only by MyApp.Blog.publish_post/1,
  # so form params cannot publish a post on their own.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts written by users.
  """

  import Ecto.Query, only: [where: 2, order_by: 2, preload: 2]

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
  Lists the user's posts newest first, with each author preloaded for display.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author. Raises `Ecto.NoResultsError` when missing,
  which Phoenix turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` and records the action in the audit log. Both writes commit
  together or roll back together.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_audit_log(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp insert_audit_log(post, action) do
    entry = %{
      action: action,
      subject_type: "post",
      subject_id: post.id,
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(entry)
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill lives in priv/repo/scripts/backfill_published_at.exs,
  # so this migration does not depend on application code and can run on a fresh database.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/scripts/backfill_published_at.exs
# Run once after the migration with: mix run priv/repo/scripts/backfill_published_at.exs
#
# Existing posts are published, so each gets published_at = inserted_at. The is_nil
# guard makes a second run a no-op.
import Ecto.Query, only: [from: 2]

alias MyApp.Blog.Post
alias MyApp.Repo

backfill =
  from p in Post,
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _} = Repo.update_all(backfill, [])

IO.puts("Backfilled published_at on #{count} posts")

# File: lib/my_app_web/controllers/post_controller.ex
# Route, in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

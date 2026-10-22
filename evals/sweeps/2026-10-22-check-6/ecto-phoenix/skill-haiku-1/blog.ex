# Assumptions about existing code, since none of it was shown:
#   * MyApp.Accounts.User has a `name` field and `Repo` is MyApp.Repo.
#   * MyApp.Audit.Log has a `changeset/2` that accepts :action, :resource,
#     :resource_id and :user_id. Adjust the attrs in insert_audit_log/1 if not.
#   * Ecto is 3.13+ (for Repo.transact/2).
#   * Newest first means by inserted_at.

# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user.

  `published_at` is not cast from form params. It is set only by
  `MyApp.Blog.publish_post/1`.
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
  Casts and validates the user-editable fields.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at` to the given time.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
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
  Creates a post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts written by `user`, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    query =
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]

    Repo.all(query)
  end

  @doc """
  Gets a post by id with its author preloaded.

  Raises `Ecto.NoResultsError` when the post does not exist, which Phoenix
  turns into a 404 response.
  """
  def get_post!(id) do
    post = Repo.get!(Post, id)
    Repo.preload(post, :user)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  The update and the audit row share one transaction, so either both are
  saved or neither is.

  Returns `{:ok, post}` or `{:error, reason}`.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_audit_log(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(%Post{} = post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp insert_audit_log(%Post{} = post) do
    attrs = %{
      action: "post.published",
      resource: "post",
      resource_id: post.id,
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
# Schema change only. The backfill lives in a separate script so the
# migration does not depend on application data logic.
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/scripts/backfill_published_at.exs
# Run with: mix run priv/repo/scripts/backfill_published_at.exs
# Safe to rerun: rows that already have published_at are skipped.
import Ecto.Query, only: [from: 2]

alias MyApp.Repo

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _} = Repo.update_all(query, [])
IO.puts("Backfilled published_at on #{count} posts")

# File: lib/my_app_web/controllers/post_controller.ex
# Route to add in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

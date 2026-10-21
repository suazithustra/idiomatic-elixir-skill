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

  @doc """
  Casts and validates form params. `user_id` and `published_at` are not cast,
  so a request cannot set them.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Sets `published_at` to the given time. Used only by `MyApp.Blog.publish_post/1`.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, showing, and publishing.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user
    )
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises `Ecto.NoResultsError`
  when no post has that id.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and inserts a `post.published` audit log row.

  Both writes run in one transaction. If either fails, both are rolled back
  and `{:error, reason}` is returned.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published_post} <- publish_post_row(post),
           {:ok, _log} <- insert_publish_audit_log(published_post) do
        {:ok, published_post}
      end
    end)
  end

  defp publish_post_row(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # The Log field names below are assumed. Match them to MyApp.Audit.Log.
  defp insert_publish_audit_log(%Post{} = post) do
    %Audit.Log{}
    |> Audit.Log.changeset(%{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    })
    |> Repo.insert()
  end
end

# File: priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Adds the column only. The backfill is in priv/repo/scripts/backfill_published_at.exs,
  # so the migration does not depend on application code or data.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Only rows with a NULL published_at are touched, so a re-run cannot overwrite
# a real publish time.
import Ecto.Query

alias MyApp.Blog.Post
alias MyApp.Repo

{count, _} =
  Repo.update_all(
    from(p in Post,
      where: is_nil(p.published_at),
      update: [set: [published_at: p.inserted_at]]
    )
  )

IO.puts("Backfilled published_at on #{count} posts")

# File: lib/my_app_web/controllers/post_controller.ex
# Router (lib/my_app_web/router.ex), inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

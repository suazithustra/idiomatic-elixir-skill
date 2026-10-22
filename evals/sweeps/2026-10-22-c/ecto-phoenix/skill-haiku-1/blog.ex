# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. `published_at` is nil until the post is published.
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
  Casts user-editable fields. `user_id` and `published_at` are not cast, so a
  request cannot set them; the context sets them.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc false
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating, listing, fetching, and publishing them.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Returns the user's posts newest first, with the author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    query =
      from(p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user
      )

    Repo.all(query)
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises `Ecto.NoResultsError`
  when the post does not exist, which Phoenix turns into a 404.
  """
  def get_post!(id) do
    post = Repo.get!(Post, id)
    Repo.preload(post, :user)
  end

  @doc """
  Publishes a post: sets `published_at` to now and records the action in the
  audit log. Both writes happen in one transaction, so neither persists alone.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- mark_published(post),
           {:ok, _log} <- record_publish(published) do
        {:ok, published}
      end
    end)
  end

  defp mark_published(post) do
    now = DateTime.utc_now(:second)

    post
    |> Post.publish_changeset(now)
    |> Repo.update()
  end

  # Assumes `Log.changeset/2` exists and the audit_logs table has these fields;
  # adjust the attrs to match the existing MyApp.Audit.Log schema.
  defp record_publish(post) do
    attrs = %{
      action: "post_published",
      resource: "posts",
      resource_id: post.id,
      user_id: post.user_id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Schema change only. The backfill lives in priv/repo/scripts/backfill_published_at.exs
  # so that this migration does not depend on application code or data.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Sets published_at to inserted_at for existing posts that lack it. Safe to re-run.
import Ecto.Query, only: [from: 2]

alias MyApp.Blog.Post
alias MyApp.Repo

query =
  from(p in Post,
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]
  )

{count, _} = Repo.update_all(query, [])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
# Route in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

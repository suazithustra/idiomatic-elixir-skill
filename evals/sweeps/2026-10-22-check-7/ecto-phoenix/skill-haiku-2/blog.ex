# Blog posts: context, schema, migration, backfill script, and controller.
#
# Each part below is headed by the file it would live in. Assumptions:
#   * MyApp.Audit.Log has a changeset/2 and columns action, resource,
#     resource_id, and user_id. Rename them to match the real audit_logs table.
#   * Repo.transact/2 needs Ecto 3.13+.
#   * Route: get "/posts/:id", PostController, :show (in lib/my_app_web/router.ex).
#   * The view module PostHTML and its show template exist (phx.gen.html style).
#   * The backfill is a script rather than part of the migration, because
#     data changes do not belong in schema migrations.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is set only through `publish_changeset/2`, so form params
  cannot publish a post on their own.
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
  Casts and validates the fields a writer may set.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Sets `published_at` on a post.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
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

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first, with each post's author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    query =
      from(p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]
      )

    Repo.all(query)
  end

  @doc """
  Gets a post by id. Raises `Ecto.NoResultsError` when it does not exist.
  """
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Publishes `post` by setting `published_at` to now and writing an audit log row.

  Both writes happen in one transaction. If either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post, DateTime.utc_now(:second)),
           {:ok, _log} <- record_audit(published, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post, published_at) do
    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  defp record_audit(%Post{} = post, action) do
    attrs = %{action: action, resource: "post", resource_id: post.id, user_id: post.user_id}

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261022000000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after migrating: mix run priv/repo/scripts/backfill_published_at.exs
# Safe to re-run: it only touches rows where published_at is still NULL.
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
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

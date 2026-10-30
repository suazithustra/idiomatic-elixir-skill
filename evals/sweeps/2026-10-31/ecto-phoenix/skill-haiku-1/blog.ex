# Blog posts: schema, context, migration, backfill script, controller.
# Each part is preceded by the path it would live at. Not compiled here:
# Phoenix and Ecto are not installed.
#
# Assumptions to check against the project:
# - MyApp.Audit.Log has changeset/2 accepting :action, :actor_id,
#   :subject_type and :subject_id.
# - Repo.transact/2 needs Ecto 3.13 or later.
# - The backfill is a separate script, not part of the migration, because
#   a migration should only change schema.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by one user.
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
  Validates form input for a post.

  `published_at` is not cast here. Only `publish_changeset/2` sets it, so a
  form cannot publish a post without the audit row being written.
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
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Creates, lists, reads, and publishes blog posts.
  """

  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form `params`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists `user`'s posts, newest first, with the author preloaded.

  `inserted_at` is stored to the second, so ties are broken by `id`.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Returns the post with `id`, with its author preloaded.

  Raises `Ecto.NoResultsError` when no post has that id.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` now and writes an audit log row for `actor`.

  The post update and the audit row share one transaction: if either
  fails, neither is kept. Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    published_at = DateTime.utc_now(:second)

    Repo.transact(fn ->
      with {:ok, published} <- Repo.update(Post.publish_changeset(post, published_at)),
           {:ok, _log} <- log_action(published, actor, "post.published") do
        {:ok, published}
      end
    end)
  end

  defp log_action(post, actor, action) do
    attrs = %{
      action: action,
      actor_id: actor.id,
      subject_type: "Post",
      subject_id: post.id
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

# priv/repo/scripts/backfill_published_at.exs
# Run after the migration: mix run priv/repo/scripts/backfill_published_at.exs
# Safe to re-run: only rows still missing published_at are touched.
import Ecto.Query

alias MyApp.Blog.Post
alias MyApp.Repo

query =
  from p in Post,
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _} = Repo.update_all(query)
IO.puts("Set published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
# Route, in the browser scope of lib/my_app_web/router.ex:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

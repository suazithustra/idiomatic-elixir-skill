# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post without `published_at` is a draft.
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

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_length(:title, max: 255)
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
  The Blog context: writing, listing, and publishing posts.
  """

  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Lists the posts written by `user`, newest first, with each post's `:user` preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id, with its `:user` preloaded.

  Raises `Ecto.NoResultsError` if there is no post with that id.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Creates a post written by `user` from form params.

  Returns `{:ok, post}`, or `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Publishes `post` by setting `published_at` to now, and records the action in the audit log.

  Both writes run in one transaction, so either both are saved or neither is.
  Returns `{:ok, post}`, or `{:error, changeset}` with the changeset of the write that failed.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, post} <- mark_published(post),
           {:ok, _log} <- insert_published_log(post) do
        {:ok, post}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # The attribute names assume what MyApp.Audit.Log.changeset/2 casts; match them to that schema.
  defp insert_published_log(post) do
    %Log{}
    |> Log.changeset(%{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    })
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # Existing posts are backfilled by priv/repo/scripts/backfill_post_published_at.exs,
  # so this migration stays a schema change only.
  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_post_published_at.exs
#
# Sets published_at to inserted_at for the posts that existed before drafts were introduced.
# Run it after the migration, passing the time the code that creates drafts went live:
#
#     mix run priv/repo/scripts/backfill_post_published_at.exs 2026-10-21T12:00:00Z
#
# Posts inserted after the cutoff are drafts and keep a nil published_at, so the script is
# safe to run more than once.
import Ecto.Query

[cutoff_arg] = System.argv()
{:ok, cutoff, _utc_offset} = DateTime.from_iso8601(cutoff_arg)

query =
  from p in "posts",
    where: is_nil(p.published_at) and p.inserted_at < type(^cutoff, :utc_datetime),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(query, [])
IO.puts("Set published_at on #{count} posts inserted before #{cutoff_arg}")

# lib/my_app_web/router.ex, inside the existing `scope "/", MyAppWeb` block that pipes
# through :browser:
#
#     get "/posts/:id", PostController, :show

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@post.title}
        <:subtitle>By {@post.user.name}</:subtitle>
      </.header>
      <p class="whitespace-pre-line">{@post.body}</p>
    </Layouts.app>
    """
  end
end

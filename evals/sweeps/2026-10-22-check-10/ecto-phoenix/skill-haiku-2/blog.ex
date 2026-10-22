# Assumptions, since Phoenix and Ecto cannot be compiled here:
#   - the posts table already exists with title, body, user_id and timestamps
#   - MyApp.Audit.Log has a changeset/2 and fields action, resource, resource_id, user_id
#   - MyApp.Accounts.User is an Ecto schema with an id
# Each part below is headed by the file it would live in.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user.

  `published_at` is not cast from params: only `MyApp.Blog.publish_post/2`
  sets it, so a publish always has its audit row.
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

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Writes and reads blog posts.
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
  def list_user_posts(%User{} = user) do
    query =
      from(p in Post,
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user
      )

    Repo.all(query)
  end

  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Sets `published_at` to now and records the action in the audit log.

  Both writes run in one transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_publish_log(published, actor) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(%Post{} = post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp insert_publish_log(%Post{} = post, %User{} = actor) do
    attrs = %{
      action: "post.published",
      resource: "post",
      resource_id: post.id,
      user_id: actor.id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run with: mix run priv/repo/scripts/backfill_published_at.exs
# Kept out of the migration so schema history does not depend on app data logic.
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

# Blog posts: six parts, each headed by the file it would live in.
#
# Choices made here:
# - The backfill of published_at runs in a script, not in the migration, because
#   data changes do not belong in migrations. Run it once, right after migrating.
# - Timestamps are :utc_datetime_usec, the Phoenix 1.8 default.
# - MyApp.Audit.Log is assumed to have action, resource_type, resource_id, user_id
#   fields and a changeset/2. Adjust the log attrs if its real fields differ.

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
    field :published_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
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
  Writing, listing, and publishing blog posts.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post by `user` from form `params`.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with the author preloaded.

  Ties on `inserted_at` are broken by id so the order is stable.
  """
  def list_user_posts(%User{id: user_id}) do
    from(p in Post,
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author preloaded. Raises `Ecto.NoResultsError` if missing.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post`, setting `published_at` to now and writing an audit log row.

  Both writes happen in one transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    post
    |> change(published_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id,
      user_id: post.user_id
    }

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
      add :published_at, :utc_datetime_usec
    end
  end
end

# priv/repo/scripts/backfill_published_at.exs
# Run once after `mix ecto.migrate`, before new drafts exist:
#   mix run priv/repo/scripts/backfill_published_at.exs
import Ecto.Query, only: [from: 2]

alias MyApp.Blog.Post
alias MyApp.Repo

{count, _} =
  from(p in Post,
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]
  )
  |> Repo.update_all([])

IO.puts("Backfilled published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
# Route: get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    render(conn, :show, post: Blog.get_post!(id))
  end
end

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. It is a draft until `published_at` is set.
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
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast, so a request cannot set them.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end
end

# lib/my_app/blog.ex
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
  Creates a draft post for `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their author loaded.
  """
  def list_posts(%User{id: user_id}) do
    query =
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: :user

    Repo.all(query)
  end

  @doc """
  Fetches a post by id with its author loaded. Raises `Ecto.NoResultsError`
  when there is none, which Phoenix renders as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction, so either both are saved or neither.
  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- log_publication(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    post
    |> Ecto.Changeset.change(published_at: published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has `action` and `description` fields and a
  # `changeset/2` that casts them; adjust to the real schema.
  defp log_publication(post) do
    attrs = %{
      action: "post_published",
      description: "Post #{post.id} published by user #{post.user_id}"
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
      add :published_at, :utc_datetime
    end
  end
end

# priv/repo/backfill_published_at.exs
#
# Run once right after the migration, before new drafts exist:
#
#     mix run priv/repo/backfill_published_at.exs
#
# Marks every existing post as published at the time it was inserted. It
# queries the table by name so it does not depend on the Post schema.
import Ecto.Query, only: [from: 2]

query =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, _} = MyApp.Repo.update_all(query, [])
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

# lib/my_app_web/router.ex (inside the :browser scope)
#
#     get "/posts/:id", PostController, :show

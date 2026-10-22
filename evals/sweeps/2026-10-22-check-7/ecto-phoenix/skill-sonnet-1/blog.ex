# File: priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# File: lib/my_app/release/backfill_published_at.ex
defmodule MyApp.Release.BackfillPublishedAt do
  @moduledoc """
  One-off data change that marks every post that existed before the
  `published_at` column was added as published at its `inserted_at`.

  Run it once, right after the migration and before new posts are created:
  a later run would also publish posts that are still drafts.

      bin/my_app eval "MyApp.Release.BackfillPublishedAt.run()"
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Repo

  @doc """
  Sets `published_at` to `inserted_at` on every post without a `published_at`.

  Returns the number of posts updated. It queries the `"posts"` table by name,
  so it keeps working when the `MyApp.Blog.Post` schema changes.
  """
  @spec run() :: non_neg_integer()
  def run do
    query =
      from p in "posts",
        where: is_nil(p.published_at),
        update: [set: [published_at: p.inserted_at]]

    {count, nil} = Repo.update_all(query, [])
    count
  end
end

# File: lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post with no `published_at` is a draft.
  """

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

  @doc """
  Builds a changeset from form params. `user_id` and `published_at` are set by
  the context, so they are not cast.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Builds a changeset that sets `published_at` to `published_at`.
  """
  def publish_changeset(post, %DateTime{} = published_at) do
    change(post, published_at: published_at)
  end
end

# File: lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts and their publishing.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  ## Examples

      iex> create_post(user, %{"title" => "Hello", "body" => "First post"})
      {:ok, %Post{title: "Hello"}}

      iex> create_post(user, %{"title" => ""})
      {:error, %Ecto.Changeset{}}
  """
  @spec create_post(User.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with each post's author loaded.
  """
  @spec list_user_posts(User.t()) :: [Post.t()]
  def list_user_posts(%User{} = user) do
    from(p in Post,
      where: p.user_id == ^user.id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: :user
    )
    |> Repo.all()
  end

  @doc """
  Gets one post with its author loaded.

  Raises `Ecto.NoResultsError` if the post does not exist, which Phoenix
  renders as a 404.
  """
  @spec get_post!(term()) :: Post.t()
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log. Both writes
  happen in one transaction, so if either fails neither is kept.
  """
  @spec publish_post(Post.t()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def publish_post(%Post{} = post) do
    published_at = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post, published_at),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  defp update_published_at(post, published_at) do
    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has :action, :user_id and :metadata fields and a
  # changeset/2 that casts them; adjust to the real schema.
  defp insert_publish_log(post) do
    params = %{
      action: "post.published",
      user_id: post.user_id,
      metadata: %{post_id: post.id}
    }

    %Log{}
    |> Log.changeset(params)
    |> Repo.insert()
  end
end

# File: lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# File: lib/my_app_web/router.ex (inside the existing browser-scoped block)
#
#     get "/posts/:id", PostController, :show
#
# File: lib/my_app_web/controllers/post_html/show.html.heex shows
# @post.title, @post.user.name and @post.body; a user's post list page shows
# post.title and post.user.name for each post from Blog.list_user_posts/1.

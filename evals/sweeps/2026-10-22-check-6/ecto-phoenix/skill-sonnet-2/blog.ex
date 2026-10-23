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

    timestamps()
  end

  @doc """
  Builds a changeset from form params.

  `user_id` and `published_at` are not cast: the code sets them, so a request
  cannot.
  """
  def changeset(post, params) do
    post
    |> cast(params, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Builds a changeset that marks the post as published at `published_at`.
  """
  def publish_changeset(post, published_at) do
    change(post, published_at: published_at)
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  The Blog context: posts written by users.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a draft post owned by `user` from form params.

  Returns `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their author loaded.
  """
  def list_user_posts(%User{} = user) do
    query =
      from p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^user.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [user: u]

    Repo.all(query)
  end

  @doc """
  Gets a post with its author loaded.

  Raises `Ecto.NoResultsError` if the post does not exist; Phoenix renders
  that as a 404.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Publishes `post` and records the action in the audit log.

  Both writes happen in one transaction: if either fails, neither is kept.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- update_published_at(post),
           {:ok, _log} <- insert_publish_log(published) do
        {:ok, published}
      end
    end)
  end

  defp update_published_at(post) do
    published_at = DateTime.utc_now(:second)

    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log has :action, :subject_type, :subject_id and
  # :user_id fields and a changeset/2 that casts them.
  defp insert_publish_log(post) do
    attrs = %{
      action: "post.published",
      subject_type: "post",
      subject_id: post.id,
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
      add :published_at, :utc_datetime
    end
  end
end

# lib/my_app/release_tasks/backfill_published_at.ex
# Run after the migration: MyApp.ReleaseTasks.BackfillPublishedAt.run()
# Kept out of the migration so schema history does not carry data logic.
defmodule MyApp.ReleaseTasks.BackfillPublishedAt do
  @moduledoc false

  alias MyApp.Repo

  def run do
    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, fn repo -> backfill(repo) end)
    :ok
  end

  defp backfill(repo) do
    %{num_rows: count} =
      repo.query!("UPDATE posts SET published_at = inserted_at WHERE published_at IS NULL")

    count
  end
end

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

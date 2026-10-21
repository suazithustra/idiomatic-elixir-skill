# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post is a draft until `published_at` is set.
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
  Blog posts: writing, listing, and publishing them.
  """
  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Gets a post by id, with its author preloaded.

  Raises `Ecto.NoResultsError` if no post has that id.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Lists the posts written by `user`, newest first, with each post's author
  preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Creates a post written by `user` from form params.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Publishes `post` now and records the action in the audit log.

  Both writes run in one transaction, so if either fails neither is kept.
  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published_post} <- mark_published(post),
           {:ok, _log} <- log_published(published_post) do
        {:ok, published_post}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # These field names are assumed; match them to MyApp.Audit.Log's schema.
  defp log_published(post) do
    Repo.insert(%Log{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id
    })
  end
end

# priv/repo/migrations/20261021120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end
  end
end

# lib/my_app/release/backfill_post_published_at.ex
defmodule MyApp.Release.BackfillPostPublishedAt do
  @moduledoc """
  Sets `published_at` to `inserted_at` on the posts that existed before the
  `AddPublishedAtToPosts` migration ran.

  Posts created after that migration are drafts until they are published, so
  only rows inserted before the migration are updated. Running it again
  changes nothing.

  Run it once after the migration, from a release:

      bin/my_app eval "MyApp.Release.BackfillPostPublishedAt.run()"

  or in development:

      mix run -e "MyApp.Release.BackfillPostPublishedAt.run()"
  """
  import Ecto.Query

  @app :my_app
  @migration_version 20_261_021_120_000

  @doc """
  Runs the backfill and prints how many posts it updated.
  """
  def run do
    load_app()
    {:ok, count, _started_apps} = Ecto.Migrator.with_repo(MyApp.Repo, &backfill/1)
    IO.puts("Set published_at on #{count} posts.")
  end

  # Queries the tables directly instead of using MyApp.Blog.Post, so the
  # script keeps working if the schema module changes later.
  defp backfill(repo) do
    migrated_at = migrated_at(repo)

    query =
      from p in "posts",
        where: is_nil(p.published_at) and p.inserted_at <= ^migrated_at,
        update: [set: [published_at: p.inserted_at]]

    {count, nil} = repo.update_all(query, [])
    count
  end

  defp migrated_at(repo) do
    query =
      from m in "schema_migrations",
        where: m.version == ^@migration_version,
        select: m.inserted_at

    repo.one!(query)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
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

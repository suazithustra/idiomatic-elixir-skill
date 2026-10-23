# Each part below is a separate file in the Phoenix app; the comment above each
# part names the file it would live in.
#
# Assumes the existing posts table has title, body, user_id and
# timestamps(type: :utc_datetime), and that MyApp.Audit.Log has a changeset/2
# accepting :action and :details. Adjust the audit fields to the real schema.

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  use Ecto.Schema

  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime
    belongs_to :user, MyApp.Accounts.User

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
  Blog posts and their publication.
  """

  import Ecto.Query

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post owned by `user` from form params.

  The owner is set on the struct rather than cast, so form params cannot change it.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Lists the posts of `user`, newest first, with their author preloaded.
  """
  def list_user_posts(%User{id: user_id}) do
    Post
    |> where(user_id: ^user_id)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id with its author preloaded.

  Raises `Ecto.NoResultsError` when the post does not exist, which Phoenix
  turns into a 404 response.
  """
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Publishes `post` by setting `published_at` to now and inserting an audit log row.

  Both writes run in one transaction, so if either fails the other is rolled back.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published} <- set_published_at(post),
           {:ok, _log} <- insert_audit_log(published) do
        {:ok, published}
      end
    end)
  end

  defp set_published_at(post) do
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp insert_audit_log(post) do
    %Log{}
    |> Log.changeset(%{action: "post.published", details: %{post_id: post.id}})
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

    # Plain SQL, not the Post schema, so later schema changes cannot break this
    # migration. Backfilling here is what was asked for; the skill's advice to
    # move data changes to a script is the alternative if this must run separately.
    execute "UPDATE posts SET published_at = inserted_at", ""
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

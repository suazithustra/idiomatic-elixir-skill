# Single file holding every part of the blog feature. Each part's first
# comment line names the project file it would live in.
#
# Assumptions (Phoenix and Ecto are not installed here, so nothing is compiled):
# - The posts table already exists with user_id, title, body, and timestamps.
# - Timestamps are :utc_datetime_usec.
# - audit_logs is MyApp.Audit.Log with action, resource_type, resource_id,
#   and user_id fields, and Log.changeset/2 exists.
# - MyAppWeb.PostHTML.show/1 (the template) is not included.

# priv/repo/migrations/20261023120000_add_published_at_to_posts.exs
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime_usec
    end

    # Existing posts count as published from the moment they were created.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime_usec

    belongs_to :user, MyApp.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  # Only form fields are cast. user_id and published_at are set in code,
  # never from params.
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc "Blog posts: creating, listing, showing, and publishing."

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc "Creates a post owned by `user` from form params."
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists one user's posts, newest first, with the author preloaded."
  def list_user_posts(%User{id: user_id}) do
    from(p in Post,
      where: p.user_id == ^user_id,
      join: u in assoc(p, :user),
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [user: u]
    )
    |> Repo.all()
  end

  @doc "Gets a post by id with its author. Raises Ecto.NoResultsError if missing."
  def get_post!(id) do
    Post
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Sets `published_at` to now and inserts an audit log row. Both run in one
  transaction, so if either step fails, neither change is kept.
  """
  def publish_post(%Post{} = post) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      with {:ok, post} <- post |> Changeset.change(published_at: now) |> Repo.update(),
           {:ok, _log} <- insert_audit_log(post) do
        post
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_audit_log(%Post{} = post) do
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

# lib/my_app_web/controllers/post_controller.ex
# Route to add in lib/my_app_web/router.ex, inside the browser scope:
#   get "/posts/:id", PostController, :show
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

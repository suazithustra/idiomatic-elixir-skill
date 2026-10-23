# Everything below is one review file. The comment above each part names the
# file it would live in in a real project.
#
# Assumptions to check against the project:
#   * Post timestamps use :utc_datetime (no microseconds). If the project's
#     generators use :utc_datetime_usec, change published_at and the
#     timestamps type to match.
#   * MyApp.Audit.Log has a changeset/2 that casts :action, :subject_type,
#     :subject_id and :user_id. Rename these fields if the table uses others.
#   * The posts table already exists with user_id and inserted_at columns.

# ---------------------------------------------------------------------------
# lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
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
    # Not cast by changeset/2: only MyApp.Blog.publish_post/2 sets it.
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates the author-editable fields. The `user_id` is set by the
  caller on the struct, so a request cannot choose the author.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end
end

# ---------------------------------------------------------------------------
# lib/my_app/blog.ex
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts: creating them, listing an author's posts, and publishing.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.
  """
  def create_post(%User{} = user, params) do
    %Post{user_id: user.id}
    |> Post.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Returns the user's posts, newest first, with the author preloaded so each
  row can show the author's name.
  """
  def list_user_posts(%User{} = user) do
    from(p in Post,
      where: p.user_id == ^user.id,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises `Ecto.NoResultsError`
  when the post does not exist; Phoenix turns that into a 404 response.
  """
  def get_post!(id) do
    post = Repo.get!(Post, id)
    Repo.preload(post, :user)
  end

  @doc """
  Sets `published_at` to the current time and inserts a `post.published` row
  into `audit_logs`. Both writes commit together, or neither does.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    Repo.transact(fn ->
      with {:ok, post} <- mark_published(post),
           {:ok, _log} <- log_publish(post, actor) do
        {:ok, post}
      end
    end)
  end

  defp mark_published(post) do
    post
    |> Ecto.Changeset.change(published_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp log_publish(post, actor) do
    attrs = %{
      action: "post.published",
      subject_type: "Post",
      subject_id: post.id,
      user_id: actor.id
    }

    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# priv/repo/migrations/<timestamp>_add_published_at_to_posts.exs
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  # The backfill is in this migration because the request asked for it here.
  # It is plain SQL and uses no application schema modules, so it does not
  # depend on the current Post schema.
  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---------------------------------------------------------------------------
# lib/my_app_web/router.ex (inside the browser scope)
#
#   get "/posts/:id", PostController, :show
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# lib/my_app_web/controllers/post_controller.ex
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

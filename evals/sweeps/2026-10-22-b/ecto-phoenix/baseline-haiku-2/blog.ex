# ---------------------------------------------------------------------------
# File: priv/repo/migrations/20261022120000_add_published_at_to_posts.exs
#
# Assumes posts.inserted_at is a :utc_datetime column (Phoenix 1.8 default
# `timestamps(type: :utc_datetime)`), so published_at uses the same type.
# ---------------------------------------------------------------------------
defmodule MyApp.Repo.Migrations.AddPublishedAtToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :published_at, :utc_datetime
    end

    # Existing posts are treated as published when they were created.
    execute "UPDATE posts SET published_at = inserted_at"
  end

  def down do
    alter table(:posts) do
      remove :published_at
    end
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog/post.ex
# ---------------------------------------------------------------------------
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
    |> cast(attrs, [:title, :body, :published_at])
    |> validate_required([:title, :body])
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app/blog.ex
#
# Assumptions about the existing audit code, adjust if they differ:
#   - MyApp.Audit.Log has a changeset/2 that casts :action, :user_id,
#     :resource and :resource_id.
#   - The audit_logs table has those columns.
# ---------------------------------------------------------------------------
defmodule MyApp.Blog do
  @moduledoc """
  Blog posts written by users.
  """

  import Ecto.Query, only: [from: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post for `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns one user's posts, newest first, with the author preloaded
  so the page can show each author's name.
  """
  def list_user_posts(%User{id: user_id}) do
    Repo.all(
      from p in Post,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        preload: [:user]
    )
  end

  @doc """
  Fetches a post by id with its author preloaded. Raises if not found.
  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(:user)
  end

  @doc """
  Sets `published_at` to now and inserts an audit log row for the action.
  Both writes run in one transaction: either both happen or neither does.
  """
  def publish_post(%Post{} = post, %User{} = actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with {:ok, post} <- post |> Ecto.Changeset.change(published_at: now) |> Repo.update(),
           {:ok, _log} <- insert_audit_log(actor, post) do
        post
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_audit_log(actor, post) do
    %Log{}
    |> Log.changeset(%{
      action: "post_published",
      user_id: actor.id,
      resource: "post",
      resource_id: post.id
    })
    |> Repo.insert()
  end
end

# ---------------------------------------------------------------------------
# File: lib/my_app_web/controllers/post_controller.ex
#
# Phoenix 1.8 HTML controllers render through a PostHTML module with a
# show/1 function component (or show.html.heex) in lib/my_app_web/controllers/post_html/.
# A missing id raises Ecto.NoResultsError, which Phoenix turns into a 404.
# ---------------------------------------------------------------------------
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    render(conn, :show, post: post)
  end
end

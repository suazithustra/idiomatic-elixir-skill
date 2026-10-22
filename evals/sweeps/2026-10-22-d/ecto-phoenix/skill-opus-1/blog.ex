# lib/my_app/blog/post.ex
defmodule MyApp.Blog.Post do
  @moduledoc """
  A blog post written by a user. A post is a draft until `published_at` is set.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MyApp.Accounts.User

  @type t :: %__MODULE__{}

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for the fields a user can edit.

  `user_id` and `published_at` are set by the code, never cast from params.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
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
  The Blog context: creating, listing, and publishing posts.
  """

  import Ecto.Query, only: [where: 2, order_by: 2, preload: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Creates a post written by `user` from form params.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts written by `user`, newest first, with the author preloaded.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a post by id. Raises `Ecto.NoResultsError` if it does not exist.
  """
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Publishes `post` and records the action in the audit log, in one transaction.

  Returns `{:ok, post}`, or `{:error, changeset}` with nothing written.
  """
  def publish_post(%Post{} = post) do
    Repo.transact(fn ->
      with {:ok, published_post} <- mark_published(post),
           {:ok, _log} <- log_publication(published_post) do
        {:ok, published_post}
      end
    end)
  end

  defp mark_published(post) do
    published_at = DateTime.utc_now(:second)

    post
    |> Post.publish_changeset(published_at)
    |> Repo.update()
  end

  # Assumes MyApp.Audit.Log.changeset/2 casts these fields; adjust the
  # attribute names to the audit_logs columns.
  defp log_publication(post) do
    log_attrs = %{
      action: "post.published",
      user_id: post.user_id,
      resource_type: "post",
      resource_id: post.id
    }

    %Log{}
    |> Log.changeset(log_attrs)
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

# priv/repo/scripts/backfill_posts_published_at.exs
#
# Run once after the migration above is deployed, passing the deploy time:
#
#     mix run priv/repo/scripts/backfill_posts_published_at.exs 2026-10-22T12:00:00Z
#
# The cutoff keeps drafts created after the deploy from being marked as
# published.
import Ecto.Query, only: [from: 2]

alias MyApp.Blog.Post
alias MyApp.Repo

[cutoff_arg] = System.argv()
{:ok, cutoff, _offset} = DateTime.from_iso8601(cutoff_arg)

backfill_query =
  from p in Post,
    where: is_nil(p.published_at) and p.inserted_at < ^cutoff,
    update: [set: [published_at: p.inserted_at]]

{count, _rows} = Repo.update_all(backfill_query, [])
IO.puts("Set published_at on #{count} posts")

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

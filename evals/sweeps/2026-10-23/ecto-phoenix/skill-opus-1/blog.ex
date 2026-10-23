# lib/my_app/blog/post.ex
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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates the fields a user fills in on the post form.

  The author and the publication date are set by code, not by the form.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> assoc_constraint(:user)
  end

  @doc """
  Returns a changeset that marks the post as published at `published_at`.
  """
  def publish_changeset(post, published_at), do: change(post, published_at: published_at)
end

# lib/my_app/blog.ex
defmodule MyApp.Blog do
  @moduledoc """
  Writing, listing and publishing blog posts.
  """

  import Ecto.Query, only: [order_by: 2, preload: 2, where: 2]

  alias MyApp.Accounts.User
  alias MyApp.Audit.Log
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Returns the post with the given id.

  Raises `Ecto.NoResultsError` when there is none, which Phoenix renders as a 404.
  """
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Creates a post written by `user` from the post form's params.

  Returns `{:ok, post}`, or `{:error, changeset}` when the params are invalid.
  """
  def create_post(%User{} = user, attrs) do
    %Post{user_id: user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the posts written by `user`, newest first, with each post's `user`
  preloaded so a page can show the author's name without a query per post.
  """
  def list_user_posts(%User{} = user) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Publishes `post` now and records the action in the audit log.

  Both writes run in one transaction: if either fails, neither is saved.
  Returns `{:ok, post}` or `{:error, changeset}`.
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
    post
    |> Post.publish_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  # The audit_logs columns are not shown here: this assumes Log.changeset/2
  # casts these fields. Rename the keys to match the table.
  defp log_publication(post) do
    log_attrs = %{
      action: "post.published",
      resource_type: "post",
      resource_id: post.id
    }

    %Log{}
    |> Log.changeset(log_attrs)
    |> Repo.insert()
  end
end

# priv/repo/migrations/20261023120000_add_published_at_to_posts.exs
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
# Run once with `mix run priv/repo/scripts/backfill_posts_published_at.exs`,
# right after the AddPublishedAtToPosts migration and before the new code
# creates any post: from then on a NULL published_at marks a draft, and this
# script would publish it.
import Ecto.Query

posts_without_published_at =
  from p in "posts",
    where: is_nil(p.published_at),
    update: [set: [published_at: p.inserted_at]]

{count, nil} = MyApp.Repo.update_all(posts_without_published_at, [])
IO.puts("Set published_at on #{count} posts")

# lib/my_app_web/router.ex, inside the existing browser `scope "/", MyAppWeb`:
#
#     get "/posts/:id", PostController, :show

# lib/my_app_web/controllers/post_controller.ex
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end
end

# lib/my_app_web/controllers/post_html.ex
defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>{@post.title}</.header>
      <p class="whitespace-pre-line">{@post.body}</p>
    </Layouts.app>
    """
  end
end

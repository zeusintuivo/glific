defmodule Glific.Caches do
  @moduledoc """
  Glific Cache management
  """
  @cache_bucket :glific_cache

  @behaviour Glific.Caches.CacheBehaviour

  # set timer limit
  @ttl_limit 24

  @doc """
  Store all the in cachex :flows_cache. At some point, we will just use this dynamically
  """
  @impl Glific.Caches.CacheBehaviour
  @spec set(non_neg_integer, list(), (any() -> any()), map()) :: {:ok, any()}
  def set(organization_id, keys, process_fn, args),
    do: set_to_cache(organization_id, keys, process_fn.(args))

  @doc false
  @impl Glific.Caches.CacheBehaviour
  @spec set(non_neg_integer, any(), any()) :: {:ok, any()}
  def set(organization_id, keys, value) when is_list(keys),
    do: set_to_cache(organization_id, keys, value)

  @doc false
  @impl Glific.Caches.CacheBehaviour
  def set(organization_id, key, value), do: set_to_cache(organization_id, [key], value)

  @doc false
  @spec set_to_cache(non_neg_integer, list(), any) :: {:ok, any()}
  defp set_to_cache(organization_id, keys, value) do
    keys = Enum.reduce(keys, [], fn key, acc -> [{{organization_id, key}, value} | acc] end)

    # also update the reload key for consumers to refresh caches
    keys = [{{organization_id, :cache_reload_key}, Ecto.UUID.generate()} | keys]

    {:ok, true} = Cachex.put_many(@cache_bucket, keys, ttl: :timer.hours(@ttl_limit))
    {:ok, value}
  end

  @doc """
  Get a cached value based on a key
  """
  @impl Glific.Caches.CacheBehaviour
  @spec get(non_neg_integer, any(), Keyword.t()) :: {:ok, any()} | {:ok, false}
  def get(organization_id, key, opts \\ []) do
    case Cachex.exists?(@cache_bucket, {organization_id, key}) do
      {:ok, true} ->
        refresh_cache = Keyword.get(opts, :refresh_cache, true)
        if refresh_cache, do: Cachex.refresh(@cache_bucket, {organization_id, key})
        Cachex.get(@cache_bucket, {organization_id, key})

      _ ->
        {:ok, false}
    end
  end

  @doc """
  Get a cached value based on a key with fallback
  """
  @impl Glific.Caches.CacheBehaviour
  @spec fetch(non_neg_integer, any(), (any() -> any())) ::
          {:ok | :error | :commit | :ignore, any()}
  def fetch(organization_id, key, fallback_fn) do
    Cachex.fetch(@cache_bucket, {organization_id, key}, fallback_fn)
  end

  @doc """
  Remove a value from the cache
  """
  @impl Glific.Caches.CacheBehaviour
  @spec remove(non_neg_integer, list()) :: any()
  def remove(organization_id, keys),
    do:
      Enum.map(keys, fn key ->
        {:ok, _} = Cachex.del(@cache_bucket, {organization_id, key})
      end)

  @doc """
  Set a global value, ttl is in number of hours
  For global keys, we expect relatively short ttls
  """
  @spec put_global(any, any, non_neg_integer) :: {:ok | :error, boolean()}
  def put_global(key, value, ttl),
    do: Cachex.put(@cache_bucket, {:global, key}, value, ttl: :timer.hours(ttl))

  @doc """
  Retrieve a global value from the cache global scope
  """
  @spec get_global(any()) :: {:ok | :error, any()}
  def get_global(key),
    do: Cachex.get(@cache_bucket, {:global, key})
end

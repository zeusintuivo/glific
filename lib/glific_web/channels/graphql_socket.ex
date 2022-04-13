defmodule GlificWeb.GraphqlWSSocket do
  use Absinthe.GraphqlWS.Socket, schema: GlificWeb.Schema

  alias GlificWeb.APIAuthPlug
  require Logger
  @impl true

  def handle_init(wow, soc) do
    # IO.inspect(wow)
    # IO.inspect(soc)
    IO.inspect("soc123")
    # IO.inspect(%Plug.Conn{secret_key_base: soc.endpoint.config(:secret_key_base)})

    %Plug.Conn{secret_key_base: soc.endpoint.config(:secret_key_base)}
    |> APIAuthPlug.get_credentials(wow["authToken"], soc.connect_info.pow_config)
    |> case do
      nil ->
        :error

      {user, metadata} ->
        Logger.info("Verifying tokens: user_id: '#{user.id}'")
        fingerprint = Keyword.fetch!(metadata, :fingerprint)

        [context] = soc.absinthe.opts

        {_new, pubsub} = context

        combined_pub = pubsub |> Map.put(:current_user, user)

        assign = soc.absinthe |> Map.put(:opts, combined_pub)

        socket =
          soc
          |> assign(:session_fingerprint, fingerprint)
          |> assign(:user, user)
          |> Map.put(:absinthe, assign)

        Glific.Repo.put_current_user(user)
        Glific.Repo.put_organization_id(user.organization_id)

        IO.inspect("soc1234")

        IO.inspect(socket)
        {:ok, socket}
    end

    # IO.inspect(wow)
    # IO.inspect("wow12")
    # IO.inspect(soc)
    # case find_user(user_id) do
    #   nil ->
    #     {:error, %{}, socket}

    #   user ->
    #     socket = assign_context(socket, current_user: user)
    #     {:ok, %{name: user.name}, socket}
    # end
  end

  @impl true

  def handle_message({:thing, thing}, socket) do
    {:ok, assign(socket, :thing, thing)}
  end

  def handle_message({:send, id, payload}, socket) do
    {:push, {:text, Message.Next.new(id, payload)}, socket}
  end

  def handle_message(_msg, socket) do
    IO.inspect("wow12")
    IO.inspect(socket)
    {:ok, socket}
  end

  # @doc false
  # def start_link(opts) do
  #   GenServer.start_link(
  #     __MODULE__,
  #     opts
  #   )
  # end

  # def connect(args) do
  #   IO.inspect(args)

  #   # %Plug.Conn{secret_key_base: socket.endpoint.config(:secret_key_base)}
  #   # |> APIAuthPlug.get_credentials(token, config)

  #   IO.inspect("socketer")
  # end
end

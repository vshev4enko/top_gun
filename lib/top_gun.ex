defmodule TopGun do
  @moduledoc """
  A bihaviour module for implementing websocket client.

    # Example

      defmodule WsClient do
        use TopGun

        def start_link do
          TopGun.start_link("wss://ws.test.com", __MODULE__, name: {:local, __MODULE__})
        end

        @impl true
        def handle_connect(_headers, state) do
          subscribe = %{action: "subscribe", channels: [...]}]}
          {:reply, {:text, Jason.encode!(subscribe)}, state}
        end

        @impl true
        def handle_disconnect(_reason, state) do
          {:reconnect, 5000, state}
        end

        @impl true
        def handle_frame({:text, _message}, state) do
          {:noreply, state}
        end

        @impl true
        def handle_cast(message, state) do
          {:noreply, state}
        end

        @impl true
        def handle_info(message, state) do
          {:noreply, state}
        end

        @impl true
        def terminate(_reason, _state) do
          :ok
        end
      end

      # Start the client
      {:ok, pid} = WsClient.start_link()

      # Sends frame into opened ws connection
      TopGun.send_frame(pid, {:text, %{hello: :world}})
      #=> :ok

      # Sends cast message to TopGun process, invokes handle_cast/2 callback
      TopGun.cast(pid, :reconnect)
      #=> :ok

      # Sends raw message to TopGun process, invokes handle_info/2 callback
      send(pid, :terminate)
      #=> :terminate
  """

  @type ws_frame() :: :gun.ws_frame()

  @callback handle_connect(headers :: list(), state :: term()) ::
              {:reply, reply :: ws_frame(), new_state :: term()}
              | {:noreply, new_state :: term()}
  @callback handle_disconnect(reason :: term(), state :: term()) ::
              {:reconnect, new_state :: term()}
              | {:reconnect, timeout :: timeout(), new_state :: term()}
              | {:noreply, new_state :: term()}
              | {:stop, reason :: term(), new_state :: term()}
  @callback handle_frame(frame :: ws_frame(), state :: term()) ::
              {:reply, reply :: ws_frame(), new_state :: term()}
              | {:noreply, new_state :: term()}
              | {:stop, reason :: term(), new_state :: term()}
  @callback handle_cast(request :: term(), state :: term()) ::
              {:reply, reply :: ws_frame(), new_state :: term()}
              | {:noreply, new_state :: term()}
              | {:stop, reason :: term(), new_state :: term()}
  @callback handle_info(message :: term(), state :: term()) ::
              {:reply, reply :: ws_frame(), new_state :: term()}
              | {:noreply, new_state :: term()}
              | {:stop, reason :: term(), new_state :: term()}
  @callback terminate(reason :: term(), state :: term()) ::
              any()

  @optional_callbacks handle_connect: 2,
                      handle_disconnect: 2,
                      handle_cast: 2,
                      handle_info: 2,
                      terminate: 2

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour TopGun

      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      defoverridable child_spec: 1

      @impl true
      def handle_connect(_headers, state) do
        {:noreply, state}
      end

      @impl true
      def handle_disconnect(_reason, state) do
        {:reconnect, 5000, state}
      end

      @impl true
      def handle_cast(_request, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        raise "attempted to cast TopGun #{inspect(proc)} but no handle_cast/2 clause was provided"
        {:noreply, state}
      end

      @impl true
      def handle_info(message, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        :logger.error(%{
          label: {TopGun, :no_handle_info},
          report: %{
            module: __MODULE__,
            message: message,
            name: proc
          }
        })

        {:noreply, state}
      end

      @impl true
      def terminate(_reason, _state) do
        :ok
      end

      defoverridable handle_connect: 2,
                     handle_disconnect: 2,
                     handle_cast: 2,
                     handle_info: 2,
                     terminate: 2
    end
  end

  @type start_arg() ::
          {:name, :gen_server.server_name()}
          | {:conn_opts, :gun.opts()}

  @spec start_link(String.t(), module(), [start_arg()]) :: GenServer.on_start()
  def start_link(url, module, args \\ []) do
    :top_gun.start_link(to_charlist(url), module, args)
  end

  @type client() :: :gen_server.server_ref()

  @spec send_frame(client(), ws_frame() | [ws_frame()]) :: :ok
  defdelegate send_frame(client, frames), to: :top_gun

  @spec cast(client(), term()) :: :ok
  defdelegate cast(client, message), to: :top_gun
end

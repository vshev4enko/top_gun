defmodule TopGun.WsServer do
  @behaviour :cowboy_websocket

  def send_message(message), do: send_frame({:text, Jason.encode!(message)})

  def send_frame(frame), do: send(__MODULE__, {:send_frame, frame})

  def child_spec(opts) do
    {send_to, opts} = Keyword.pop!(opts, :send_to)
    opts = Keyword.put_new(opts, :port, 4000)

    state = %{send_to: send_to}

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: __MODULE__,
      options: opts,
      dispatch: [{:_, [{:_, __MODULE__, state}]}]
    )
  end

  @impl true
  def init(req, state) do
    {:cowboy_websocket, req, state}
  end

  @impl true
  def websocket_init(state) do
    send(state.send_to, :websocket_init)
    true = Process.register(self(), __MODULE__)
    {:ok, state}
  end

  @impl true
  def websocket_handle({:text, message}, state) do
    message =
      case Jason.decode(message) do
        {:ok, message} -> message
        {:error, _} -> message
      end

    send(state.send_to, {:ws_server_message, message})
    {[], state}
  end

  def websocket_handle({:ping, term}, state) do
    {[{:pong, term}], state}
  end

  def websocket_handle(:ping, state) do
    {[:pong], state}
  end

  @impl true
  def websocket_info({:send_frame, frame}, state) do
    {List.wrap(frame), state}
  end
end

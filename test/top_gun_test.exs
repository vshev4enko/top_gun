defmodule TopGunTest do
  use ExUnit.Case

  defmodule WsClient do
    use TopGun

    def start_link(opts) do
      {url, opts} = Keyword.pop!(opts, :url)
      {handler, opts} = Keyword.pop!(opts, :handler)
      TopGun.start_link(url, handler, opts)
    end

    @impl true
    def handle_connect(headers, state) do
      send(state.send_to, {:ws_client_connect, headers})
      {:noreply, state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      send(state.send_to, {:ws_client_disconnect, reason})
      {:reconnect, 5000, state}
    end

    @impl true
    def handle_frame(frame, state) do
      send(state.send_to, {:ws_client_frame, frame})
      {:noreply, state}
    end

    @impl true
    def handle_cast({:reply, frame} = message, state) do
      send(state.send_to, {:ws_client_cast, message})
      {:reply, frame, state}
    end

    def handle_cast({:stop, reason} = message, state) do
      send(state.send_to, {:ws_client_cast, message})
      {:stop, reason, state}
    end

    def handle_cast(message, state) do
      send(state.send_to, {:ws_client_cast, message})
      {:noreply, state}
    end

    @impl true
    def handle_info(message, state) do
      send(state.send_to, {:ws_client_info, message})
      {:noreply, state}
    end

    @impl true
    def terminate(reason, state) do
      send(state.send_to, {:ws_client_terminate, reason})
      :ok
    end
  end

  setup do
    port = 8000

    start_supervised!({TopGun.WsServer, send_to: self(), port: port}, id: WsServer)

    start_supervised!(
      {WsClient,
       name: {:local, WsClient},
       url: "ws://localhost:#{port}",
       handler: {WsClient, %{send_to: self()}},
       conn_opts: %{ws_opts: %{closing_timeout: 1}}}
    )

    assert_receive :websocket_server_init, 1000

    :ok
  end

  describe "handle_connect/2" do
    test "invoke handle_connect callback on connect" do
      assert_receive {:ws_client_connect, _headers}
    end
  end

  describe "handle_disconnect/2" do
    test "invokes handle_disconnect when connection closed" do
      TopGun.WsServer.send_frame(:close)

      assert_receive {:ws_client_frame, :close}
      assert_receive {:ws_client_disconnect, _reason}
    end
  end

  describe "handle_frame/2" do
    test "invokes handle_frame on incoming frame" do
      TopGun.WsServer.send_frame({:text, "hello world"})

      assert_receive {:ws_client_frame, {:text, "hello world"}}
    end
  end

  describe "send_frame/2" do
    test "skip frames in disconnected state" do
      TopGun.send_frame(WsClient, {:text, "hello world 1"})
      TopGun.send_frame(WsClient, {:text, "hello world 2"})
      TopGun.send_frame(WsClient, {:text, "hello world 3"})

      assert_receive {:ws_client_connect, _headers}

      TopGun.send_frame(WsClient, {:text, "hello world 4"})

      assert_receive {:ws_server_message, "hello world 4"}
    end
  end

  describe "handle_cast/2" do
    setup do
      assert_receive {:ws_client_connect, _headers}, 1000
      :ok
    end

    test "invokes handle_cast/2 callback on `TopGun.cast/2` call" do
      TopGun.cast(WsClient, :hi_there)

      assert_receive {:ws_client_cast, :hi_there}
    end

    test "sends frame to the server when callback return is {reply, frame, state}" do
      frame = {:text, "hello"}
      TopGun.cast(WsClient, {:reply, frame})

      assert_receive {:ws_client_cast, {:reply, ^frame}}
      assert_receive {:ws_server_message, "hello"}
    end

    test "terminates when callback return is {stop, reason, state}" do
      TopGun.cast(WsClient, {:stop, :normal})

      assert_receive {:ws_client_cast, {:stop, :normal}}
      assert_receive {:ws_client_terminate, :normal}
    end
  end

  describe "terminate/2" do
    test "invokes terminate/2 callback on shutdown" do
      stop_supervised!(WsClient)

      assert_receive {:ws_client_terminate, :shutdown}
    end
  end
end

%% Provides simple interface for implementing websocket clients.
-module(top_gun).

-behavior(gen_server).

%% API
-export([
    start_link/2,
    start_link/3,
    send_frame/2,
    cast/2
]).

%% Internals.
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-type ws_frame() :: gun:ws_frame().

%%%=========================================================================
%%%  API
%%%=========================================================================

-callback handle_connect(Headers :: list(), State :: term()) ->
    {reply, Reply :: ws_frame(), NewState :: term()}
    | {noreply, NewState :: term()}.
-callback handle_disconnect(Reason :: term(), State :: term()) ->
    {reconnect, NewState :: term()}
    | {reconnect, Timeout :: timeout(), NewState :: term()}
    | {noreply, NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback handle_frame(Frame :: ws_frame(), State :: term()) ->
    {reply, Reply :: ws_frame() | [ws_frame()], NewState :: term()}
    | {noreply, NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback handle_cast(Request :: term(), State :: term()) ->
    {reply, Reply :: ws_frame() | [ws_frame()], NewState :: term()}
    | {noreply, NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Message :: term(), State :: term()) ->
    {reply, Reply :: ws_frame() | [ws_frame()], NewState :: term()}
    | {noreply, NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback terminate(Reason :: term(), State :: term()) ->
    any().

-optional_callbacks([handle_connect/2, handle_disconnect/2, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    uri           :: uri_string:uri_map(),
    conn          :: undefined | pid(),
    monitor       :: undefined | reference(),
    stream        :: undefined | reference(),
    connected     :: boolean(),
    conn_opts     :: gun:opts(),
    handler       :: module(),
    handler_state :: term()
}).

-type start_arg() ::
    {name, gen_server:server_name()}
    | {handler_state, term()}
    | {conn_opts, gun:opts()}.
-export_type([start_arg/0]).

-spec start_link(string:grapheme_cluster(), module()) -> gen_server:start_ret().
start_link(Url, Module) ->
    start_link(Url, Module, []).

-spec start_link(string:grapheme_cluster(), module(), [start_arg()]) -> gen_server:start_ret().
start_link(Url, Module, Args) ->
    case proplists:get_value(name, Args) of
        undefined -> gen_server:start_link(?MODULE, {Url, Module, Args}, []);
        Name -> gen_server:start_link(Name, ?MODULE, {Url, Module, Args}, [])
    end.

-type client() :: gen_server:server_ref().

-spec send_frame(client(), ws_frame() | [ws_frame()]) -> ok.
send_frame(Client, Frames) ->
    gen_server:cast(Client, {send_frame, Frames}).

-spec cast(client(), term()) -> ok.
cast(Client, Message) ->
    gen_server:cast(Client, {cast, Message}).

init({Url, Module, Args}) ->
    process_flag(trap_exit, true),
    ConnOpts     = proplists:get_value(conn_opts, Args, #{}),
    HandlerState = proplists:get_value(handler_state, Args),

    State = #state{
        uri           = parse_url(Url),
        conn_opts     = ConnOpts#{retry => 0, protocols => [http]},
        connected     = false,
        handler       = Module,
        handler_state = HandlerState
    },
    {ok, State, {continue, connect}}.

handle_continue(connect, #state{uri = #{host := Host, port := Port}, conn_opts = ConnOpts} = State) ->
    {ok, Conn} = gun:open(Host, Port, ConnOpts),
    Ref = monitor(process, Conn),
    {noreply, State#state{conn = Conn, monitor = Ref}}.

handle_call(_Request, _from, State) ->
    {reply, not_implemented, State}.

handle_cast({send_frame, Frames}, #state{conn = Conn, stream = Stream} = State) ->
    ok = gun:ws_send(Conn, Stream, Frames),
    {noreply, State};
handle_cast({cast, Message}, State) ->
    {noreply, dispatch(State, handle_cast, [Message])}.

% handles connect to the server
handle_info({gun_up, Conn, _Proto}, #state{uri = #{path := Path}, conn_opts = ConnOpts} = State) ->
    Stream = gun:ws_upgrade(Conn, Path, [], maps:get(ws_opts, ConnOpts, #{})),
    {noreply, State#state{stream = Stream}};
% skip gun_down event to invoke handle_disconnect on `DOWN` monitor.
handle_info({gun_down, Conn, _Proto, _Reason, _Streams}, #state{conn = Conn} = State) ->
    {noreply, State};
% handles ws conn establisment
handle_info({gun_upgrade, Conn, Stream, [<<"websocket">>], Headers}, #state{conn = Conn, stream = Stream} = State) ->
    NewState = State#state{connected = true},
    {noreply, dispatch(NewState, handle_connect, [Headers])};
% handles incoming frames
handle_info({gun_ws, Conn, Stream, Frame}, #state{conn = Conn, stream = Stream} = State) ->
    {noreply, dispatch(State, handle_frame, [Frame])};
handle_info({shutdown, Reason}, State) ->
    {stop, Reason, State};
handle_info({'DOWN', Ref, process, Conn, Reason}, #state{conn = Conn, monitor = Ref} = State) ->
    NewState = State#state{conn = undefined, monitor = undefined, stream = undefined, connected = false},
    {noreply, dispatch(NewState, handle_disconnect, [Reason])};
handle_info({internal, reconnect}, #state{} = State) ->
    {noreply, State, {continue, connect}};
handle_info(Message, #state{} = State) ->
    {noreply, dispatch(State, handle_info, [Message])}.

terminate(Reason, #state{conn = Conn, connected = Connected} = State) ->
    Connected andalso gun:shutdown(Conn),
    dispatch(State, terminate, [Reason]).

dispatch(#state{handler = Handler, handler_state = HandlerState} = State, Function, Args) ->
    case apply(Handler, Function, Args ++ [HandlerState]) of
        {noreply, NewHandlerState} ->
            State#state{handler_state = NewHandlerState};
        {reply, Frames, NewHandlerState} when Function == handle_connect orelse Function == handle_frame orelse Function == handle_cast orelse Function == handle_info ->
            #state{conn = Conn, stream = Stream} = State,
            ok = gun:ws_send(Conn, Stream, Frames),
            State#state{handler_state = NewHandlerState};
        {stop, Reason, NewHandlerState} when Function == handle_disconnect orelse Function == handle_frame orelse Function == handle_cast orelse Function == handle_info ->
            self() ! {shutdown, Reason},
            State#state{handler_state = NewHandlerState};
        {reconnect, Timeout, NewHandlerState} when Function == handle_disconnect orelse Function == handle_info ->
            #state{conn = Conn, monitor = Monitor, connected=Connected} = State,
            Connected andalso demonitor(Monitor, [flush]) andalso gun:close(Conn),
            NewState = State#state{conn = undefined, monitor = undefined, stream = undefined, connected = false},
            erlang:send_after(Timeout, self(), {internal, reconnect}),
            NewState#state{handler_state = NewHandlerState};
        {reconnect, NewHandlerState} when Function == handle_disconnect orelse Function == handle_info ->
            #state{conn = Conn, monitor = Monitor, connected=Connected} = State,
            Connected andalso demonitor(Monitor, [flush]) andalso gun:close(Conn),
            NewState = State#state{conn = undefined, monitor = undefined, stream = undefined, connected = false},
            self() ! {internal, reconnect},
            NewState#state{handler_state = NewHandlerState};
        _Any when Function == terminate ->
            ok
    end.

parse_url(Url) ->
    case uri_string:normalize(Url, [return_map]) of
        #{port := _} = Uri -> Uri;
        #{scheme := "wss"} = Uri -> Uri#{port => 443};
        #{scheme := "ws"} = Uri -> Uri#{port => 80}
    end.

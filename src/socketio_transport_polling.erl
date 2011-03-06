-module(socketio_transport_polling).
-include_lib("../include/socketio.hrl").
-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, {
          session_id,
          message_buffer = [],
          connection_reference,
          polling_duration,
          close_timeout,
          event_manager,
          sup
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Sup, SessionId, ConnectionReference) ->
    gen_server:start_link(?MODULE, [Sup, SessionId, ConnectionReference], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Sup, SessionId, {TransportType, Client}]) ->
    process_flag(trap_exit, true),
    PollingDuration = 
    case application:get_env(polling_duration) of
        {ok, Time} ->
            Time;
        _ ->
            20000
    end,
    CloseTimeout = 
    case application:get_env(close_timeout) of
	{ok, Time0} ->
	    Time0;
	_ ->
	    8000
    end,
    {ok, EventMgr} = gen_event:start_link(),
    send_message(TransportType, #msg{content = SessionId}, Client),
    {ok, #state{
       session_id = SessionId,
       connection_reference = {TransportType, none},
       polling_duration = PollingDuration,
       close_timeout = CloseTimeout,
       event_manager = EventMgr,
       sup = Sup
      }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% Incoming data
handle_call({TransportType, data, Client}, _From, #state{ event_manager = EventManager } = State) ->
    Req = get_request(Client),
    Data = Req:parse_post(),
    Self = self(),
    lists:foreach(fun({"data", M}) ->
        spawn(fun () ->
            F = fun(#heartbeat{}) -> ignore;
                   (M0) -> gen_event:notify(EventManager, {message, Self,  M0})
            end,
            F(socketio_data:decode(#msg{content=M}))
        end)
    end, Data),
    Response = send_message(TransportType, "ok", Client),
    {reply, Response, State};

%% Event management
handle_call(event_manager, _From, #state{ event_manager = EventMgr } = State) ->
    {reply, EventMgr, State};

%% Sessions
handle_call(session_id, _From, #state{ session_id = SessionId } = State) ->
    {reply, SessionId, State};

%% Flow control
handle_call(stop, _From, State) ->
    {stop, shutdown, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% Polling
handle_cast({TransportType, polling_request, Client, Server}, #state { polling_duration = Interval, message_buffer = [] } = State) ->
    Req = get_request(Client),
    link(Req:get(socket)),
    {noreply, State#state{ connection_reference = {TransportType, {Client, Server}} }, Interval};

handle_cast({TransportType, polling_request, Client, Server}, #state { message_buffer = Buffer } = State) ->
    gen_server:reply(Server, send_message(TransportType, {buffer, Buffer}, Client)),
    {noreply, State#state{ message_buffer = []}};

%% Send
handle_cast({send, Message}, #state{ connection_reference = {_TransportType, none}, message_buffer = Buffer } = State) ->
    {noreply, State#state{ message_buffer = lists:append(Buffer, [Message])}};

handle_cast({send, Message}, #state{ connection_reference = {TransportType, {Client, Server} }, close_timeout = _ServerTimeout } = State) ->
    gen_server:reply(Server, send_message(TransportType, Message, Client)),
    {noreply, State#state{ connection_reference = {TransportType, none} }};

handle_cast(_, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT',_Pid,_Reason}, #state{ connection_reference = { TransportType, _ }, close_timeout = ServerTimeout} = State) ->
    {noreply, State#state { connection_reference = {TransportType, none}}, ServerTimeout};

%% Connection has timed out
handle_info(timeout, #state{ connection_reference = {TransportType, {Client, Server}} } = State) ->
    gen_server:reply(Server, send_message(TransportType, "", Client)),
    {noreply, State};

%% Client has timed out
handle_info(timeout, State) ->
    {stop, shutdown, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
get_request({Req, _Index}) ->
    Req;
get_request(Req) ->
    Req.

send_message(TransportType, #msg{} = Message, Client) ->
    send_message(TransportType, socketio_data:encode(Message), Client);

send_message(TransportType, {buffer, Messages}, Client) ->
    Messages0 = lists:map(fun(M) ->
				  case M of
				      #msg{} ->
					  socketio_data:encode(M);
				      _ ->
					  M
				  end
			  end, Messages),
    send_message(TransportType, Messages0, Client);

send_message(TransportType, Message, Client) ->
    Req = get_request(Client),
    Headers = [{"Connection", "keep-alive"}],
    Headers0 = case proplists:get_value('Referer', Req:get(headers)) of
		  undefined -> Headers;
		  Origin -> [{"Access-Control-Allow-Origin", Origin}|Headers]
	      end,
    Headers1 = case proplists:get_value('Cookie', Req:get(headers)) of
		   undefined -> Headers0;
		   _Cookie -> [{"Access-Control-Allow-Credentials", "true"}|Headers0]
	       end,
    send_message(TransportType, Headers1, Message, Client).

send_message('xhr-polling', Headers, Message, Req) ->
    Headers0 = [{"Content-Type", "text/plain"}|Headers],
    Req:ok(Headers0, Message);

send_message('jsonp-polling', Headers, Message, {Req, Index}) ->
    Headers = [{"Content-Type", "text/javascript; charset=UTF-8"}|Headers],
    %% FIXME: There must be a better way of escaping Javascript?
    [_|Rest] = binary_to_list(jsx:term_to_json([list_to_binary(Message)])),
    [_|Message0] = lists:reverse(Rest),
    Message1 = "io.JSONP["++Index++"]._("++lists:reverse(Message0)++");",
    Req:ok(Headers, Message1).
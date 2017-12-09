%%% @doc A simple FastCGI client implementation.
%%% @link https://web.archive.org/web/20160119141816/http://www.fastcgi.com/drupal/node/6?q=node%2F22
%%%
%%% Copyright 2017 Marcelo Gornstein &lt;marcelog@@gmail.com&gt;
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Marcelo Gornstein <marcelog@gmail.com>
%%% @author Marcelo Gornstein <marcelog@gmail.com>
%%%
-module(erl_fastcgi).
-author("marcelog@gmail.com").
-github("https://github.com/marcelog").
-homepage("http://marcelog.github.com/").
-license("Apache License 2.0").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Constants.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-define(FCGI_VERSION_1, 1).
-define(FCGI_BEGIN_REQUEST, 1).
-define(FCGI_ABORT_REQUEST, 2).
-define(FCGI_END_REQUEST, 3).
-define(FCGI_PARAMS, 4).
-define(FCGI_STDIN, 5).
-define(FCGI_STDOUT, 6).
-define(FCGI_STDERR, 7).
-define(FCGI_DATA, 8).
-define(FCGI_GET_VALUES, 9).
-define(FCGI_GET_VALUES_RESULT, 10).
-define(FCGI_UNKNOWN_TYPE, 11).

-define(FCGI_NULL_REQUEST_ID, 0).

-define(FCGI_KEEP_CONN, 1).

-define(FCGI_RESPONDER, 1).
-define(FCGI_AUTHORIZER, 2).
-define(FCGI_FILTER, 3).

-define(FCGI_REQUEST_COMPLETE, 0).
-define(FCGI_CANT_MPX_CONN, 1).
-define(FCGI_OVERLOADED, 2).
-define(FCGI_UNKNOWN_ROLE, 3).

-define(FCGI_MAX_CONNS, "FCGI_MAX_CONNS").
-define(FCGI_MAX_REQS, "FCGI_MAX_REQS").
-define(FCGI_MPXS_CONNS, "FCGI_MPXS_CONNS").

-behavior(gen_server).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Exports.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([start_link/3, run/4, close/1]).
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  code_change/3,
  terminate/2
]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Types.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type state():: map().
-type erl_fastcgi_host():: string().
-type erl_fastcgi_port():: pos_integer().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Public API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Starts a connection to the FastCGI application server.
-spec start_link(
  erl_fastcgi_host(), erl_fastcgi_port(), pos_integer()
) -> {ok, pid()}.
start_link(Host, Port, ReconnectIntervalMillis) ->
  gen_server:start_link(?MODULE, [Host, Port, ReconnectIntervalMillis], []).

%% @doc Runs a request.
-spec run(
  pid()|atom(), non_neg_integer(), proplists:proplist(), binary()
) -> ok.
run(Server, RequestId, Params, Data) ->
  gen_server:cast(Server, {run, self(), RequestId, Params, Data}),
  ok.

%% @doc Closes the connection to the FastCGI application server and terminates
%% this client.
-spec close(pid()|atom()) -> term().
close(Server) ->
  gen_server:cast(Server, {close}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% gen_server API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc http://erlang.org/doc/man/gen_server.html#Module:init-1
-spec init([term()]) -> {ok, state()}.
init([Host, Port, ReconnectIntervalMillis]) ->
  self() ! {connect},
  {ok, #{
    sock => undefined,
    host => Host,
    port => Port,
    requests => #{},
    buffer => <<>>,
    reconnect_interval => ReconnectIntervalMillis
  }}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:handle_call-3
-spec handle_call(
  term(), {pid(), term()}, state()
) -> {reply, term(), state()}.
handle_call(
  {run, _Caller, _RequestId, _Params, _Data},
  _From,
  State = #{sock := undefined}
) ->
  {reply, not_connected, State};

handle_call(_Message, _From, State) ->
  {reply, not_implemented, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:handle_cast-2
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({run, Caller, RequestId, Params, Data}, State) ->
  #{sock := Sock, requests := Requests} = State,

  EncodedParams = encode_params(Params),

  Packet = [
    create(?FCGI_BEGIN_REQUEST, RequestId, payload_responder()),
    create(?FCGI_PARAMS, RequestId, EncodedParams),
    case Params of
      [] -> [];
      _ -> create(?FCGI_PARAMS, RequestId, <<>>)
    end,
    create(?FCGI_STDIN, RequestId, Data),
    case Data of
      <<>> -> [];
      _ -> create(?FCGI_STDIN, RequestId, <<>>)
    end
  ],
  ok = gen_tcp:send(Sock, Packet),
  NewRequests = maps:put(RequestId, Caller, Requests),
  {noreply, State#{requests := NewRequests}};

handle_cast({close}, State) ->
  #{sock := Sock, requests := Requests} = State,
  ok = gen_tcp:close(Sock),
  ok = terminate_requests(shutdown, Requests),
  {stop, normal, State#{
    sock := undefined,
    requests := #{}
  }};

handle_cast(_Message, State) ->
  {noreply, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:handle_info-2
-spec handle_info(
  term(), state()
) -> {noreply, state()} | {stop, term(), state()}.
handle_info({connect}, State) ->
  #{
    host := Host,
    port := Port,
    reconnect_interval := ReconnectIntervalMillis
  } = State,
  case gen_tcp:connect(Host, Port, [
    {active, true},
    binary,
    {packet, 0}
  ]) of
    {ok, Sock} ->
    {noreply, State#{
      sock := Sock,
      buffer := <<>>,
      requests := #{}
    }};
    _ ->
      erlang:send_after(ReconnectIntervalMillis, self(), {connect}),
      {noreply, State#{sock := undefined, requests := #{}}}
  end;

handle_info({tcp, Sock, Packet}, #{sock := Sock} = State) ->
  #{requests := Requests, buffer := Buffer} = State,

  FullPacket = <<Buffer/binary, Packet/binary>>,
  <<
    ?FCGI_VERSION_1,
    Type:8/integer,
    ReqId:16/integer,
    DataLen:16/integer,
    PadLen:8/integer,
    _Reserved:8/integer,
    DataAndPad/binary
  >> = FullPacket,
  DataToRead = PadLen + DataLen,
  case size(FullPacket) of
    X when X < DataToRead -> {noreply, State#{buffer := FullPacket}};
    _ ->
      <<Data:DataLen/binary, _Pad:PadLen/binary, Rest/binary>> = DataAndPad,
      Caller = maps:get(ReqId, Requests),
      case Type of
        ?FCGI_STDOUT -> Caller ! {fast_cgi_stdout, ReqId, Data};
        ?FCGI_STDERR -> Caller ! {fast_cgi_stderr, ReqId, Data};
        ?FCGI_END_REQUEST -> Caller ! {fast_cgi_done, ReqId}
      end,
      case size(Rest) of
        0 -> {noreply, State#{buffer := <<>>}};
        _ ->
          handle_info({tcp, Sock, Rest}, State#{buffer := <<>>})
      end
  end;

handle_info({tcp_closed, Sock}, #{sock := Sock} = State) ->
  #{
    sock := Sock,
    requests := Requests,
    reconnect_interval := ReconnectIntervalMillis
  } = State,
  ok = terminate_requests(fast_cgi_connection_reset, Requests),
  gen_tcp:close(Sock),
  erlang:send_after(ReconnectIntervalMillis, self(), {connect}),
  {stop, normal, State#{
    sock := undefined,
    requests := #{}
  }};

handle_info(_Info, State) ->
  {noreply, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:code_change-3
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:terminate-2
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
  ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Private API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Signals termination for any pending requests.
-spec terminate_requests(atom(), map()) -> ok.
terminate_requests(Reason, Requests) ->
  _ = lists:foreach(
    fun({RequestId, Caller}) ->
      Caller ! {fastcgi_request_done, RequestId, Reason}
    end,
    maps:to_list(Requests)
  ),
  ok.

%% @doc Encode a list of FastCGI params so it's ready to be sent by wire.
-spec encode_params([{string(), string()}]) -> binary().
encode_params(Params) ->
  encode_params(Params, <<>>).

%% @doc Tail-recursive version of encode_params/1
-spec encode_params([{string(), string()}], binary()) -> binary().
encode_params([], Acc) ->
  Acc;

encode_params([{Key, Value}|Params], Acc) ->
  Encoded = encode_param(list_to_binary(Key), list_to_binary(Value)),
  encode_params(Params, <<Acc/binary, Encoded/binary>>).

%% @doc Encodes a FastCGI param.
-spec encode_param(binary(), binary()) -> binary().
encode_param(Key, Value) ->
  KeyLen = size(Key),
  ValueLen = size(Value),
  <<KeyLen:8/integer, ValueLen:8/integer, Key/binary, Value/binary>>.

%% @doc Returns the binary payload for a FastCGI responder (used by a
%% FCGI_BEGIN_REQUEST).
-spec payload_responder() -> binary().
payload_responder() ->
  <<
    ?FCGI_RESPONDER:16/integer,
    ?FCGI_KEEP_CONN,
    0, 0, 0, 0, 0
  >>.

%% @doc Accumulates bits into a packet before sending it to the app server.
-spec create(non_neg_integer(), pos_integer(), binary()) -> binary().
create(Type, Id, Data) ->
  DataLen = size(Data),
  PadLen = case DataLen rem 8 of
    0 -> 0;
    Bytes -> 8 - Bytes
  end,
  PadData = pad(PadLen),

  <<
    ?FCGI_VERSION_1,
    Type:8/integer,
    Id:16/integer,
    DataLen:16/integer,
    PadLen:8/integer,
    0,
    Data/binary,
    PadData/binary
  >>.

%% @doc Returns a binary filled with 0s with the given length.
-spec pad(non_neg_integer()) -> binary().
pad(Size) ->
  pad(Size, <<>>).

pad(0, Acc) ->
  Acc;

pad(Size, Acc) ->
  pad(Size - 1, <<Acc/binary, 0>>).

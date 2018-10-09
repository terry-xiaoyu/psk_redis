%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(psk_redis).

-behaviour(gen_server).

%% APIs
-export([ start_link/0
        , psk_lookup/3
        , query/3
        , pipeline/3
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {psk_channel, psk_url}).

-define(PSK_CACHE, coaproxy_psk_cache).
-define(GET_V(K, L), proplists:get_value(K, L)).
-define(T_RESUB, timer:seconds(3600)).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

psk_lookup(psk, ClientPSKID, _PskState) ->
    case from_cache(ClientPSKID) of
        not_found ->
            from_redis(ClientPSKID);
        PSK -> {ok, PSK}
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ets:new(?PSK_CACHE, [set, public, named_table, {read_concurrency, true}]),

    RedisOpts = application:get_env(psk_redis, redis_opts, []),
    HttpOpts = application:get_env(psk_redis, http_opts, []),
    Host =  case ?GET_V(sentinel, RedisOpts) of
                undefined ->
                    proplists:get_value(host, RedisOpts);
                Sentinel ->
                    eredis_sentinel:start_link(?GET_V(servers, RedisOpts)),
                    "sentinel:" ++ Sentinel
            end,
    {ok, Sub} = eredis_sub:start_link(Host, ?GET_V(port, RedisOpts),
                                            ?GET_V(password, RedisOpts),
                                            ?GET_V(database, RedisOpts)),
    eredis_sub:controlling_process(Sub, self()),
    eredis_sub:subscribe(Sub, [?GET_V(psk_channel, RedisOpts)]),

    erlang:send_after(50, self(), post_init),
    {ok, #state{psk_channel = ?GET_V(psk_channel, RedisOpts),
                psk_url = ?GET_V(url, HttpOpts)}, 0}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({subscribed, Channel, Sub}, State) ->
    logger:debug("recv subscribed:~p", [Channel]),
    eredis_sub:ack_message(Sub),
    {noreply, State};

handle_info({message, Channel, Msg, Sub}, State = #state{psk_channel = Channel}) ->
    logger:debug("recv channel:~p, msg:~p", [Channel, Msg]),
    %% TODO: cache psk records to ets
    %%
    {CmdType, PskID, PSK} = decode_redis_psk_publish(Msg),
    handle_redis_psk_event(CmdType, PskID, PSK),
    eredis_sub:ack_message(Sub),
    {noreply, State};

handle_info({eredis_connected, Sub}, State = #state{psk_channel = Channel}) ->
    eredis_sub:subscribe(Sub, [Channel]),
    {noreply, State};

handle_info({eredis_reconnect_attempt, Sub}, State = #state{psk_channel = Channel}) ->
    eredis_sub:subscribe(Sub, [Channel]),
    {noreply, State};

handle_info(post_init, State = #state{psk_url = PskUrl}) ->
    fetch_all_psk_records(get, PskUrl, _Headers = [], _Params = <<>>),
    erlang:send_after(?T_RESUB, self(), resub),
    {noreply, State#state{}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Redis Connect/Query
%%--------------------------------------------------------------------

%% Redis Query.
query(Client, Pool, Cmd) ->
    logger:debug("redis pool:~p, cmd:~p", [Pool, Cmd]),
    eredis:q(Client, Cmd).

pipeline(Client, Pool, PipeLine) ->
    logger:debug("redis pool:~p, pipeLine:~p", [Pool, PipeLine]),
    eredis:qp(Client, PipeLine).

%% Query and cache all PSK records from db

fetch_all_psk_records(get, PskUrl, Headers, ReqBody) ->
    fetch_all_psk_records(get, PskUrl, Headers, ReqBody, 1, 500).
fetch_all_psk_records(Method, PskUrl, Headers, ReqBody, PageNum, PageSize) ->
    FullUrl = io_lib:format("~s?pageNow=~B&pageSize=~B", [PskUrl, PageNum, PageSize]),
    case psk_http:request(Method, FullUrl, Headers, ReqBody, 2) of
        {ok, 200, RespBody} ->
            %% TODO: cache these records and fetch next ones
            {PskRecords, HasMorePages} = decode_http_psk_response(RespBody),
            to_cache(PskRecords),
            if HasMorePages ->
                 fetch_all_psk_records(get, PskUrl, Headers, ReqBody, PageNum+1, PageSize);
               true ->
                 ok
            end;
        {ok, Code, _} ->
            logger:error("fetch_all_psk_records from ~p failed: ~p", [PskUrl, Code]);
        {error, _Reason} ->
            error
    end.

%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

from_cache(ClientPSKID) ->
    case ets:lookup(?PSK_CACHE, ClientPSKID) of
        [{_K, PSK}] ->
            logger:debug("lookup for psk_id: ~p, found psk: ~p", [ClientPSKID, PSK]),
            PSK;
        [] ->
            not_found
    end.

to_cache(undefined) -> ok;
to_cache(PskRecords) ->
    logger:debug("storing records: ~p", [PskRecords]),
    ets:insert(?PSK_CACHE, [{PskId, PSK} ||
                            #{<<"pskId">> := PskId, <<"pskValue">> := PSK} <- PskRecords]).

from_redis(ClientPSKID) ->
    case query_redis(ClientPSKID) of
        not_found -> error;
        PSK -> {ok, PSK}
    end.

%% Read from a Redis Hash
query_redis(_ClientPSKID) ->
    not_found.

decode_http_psk_response(HttpRespBody) ->
    try
        #{<<"result">> := Result} = jsx:decode(HttpRespBody, [return_maps]),
        #{<<"list">> := PskList, <<"hasNextPage">> := HasMore} = Result,
        {PskList, HasMore}
    catch
        Err:Reason:StackT ->
            logger:error("~p failed: ~p", [?FUNCTION_NAME, {Err,Reason,StackT}]),
            {undefined, false}
    end.

decode_redis_psk_publish(Msg) ->
    try
        [CmdType, Rem] = binary:split(Msg, <<"/">>),
        case binary:split(Rem, <<"/">>) of
            [PskID, PSK] ->
                {cmd_type(CmdType), PskID, PSK};
            [PskID] ->
                {cmd_type(CmdType), PskID, undefined}
        end
    catch
        Err:Reason:StackT ->
            logger:error("~p failed: ~p", [?FUNCTION_NAME, {Err,Reason,StackT}]),
            {unknown_cmd_type, undefined, undefined}
    end.

cmd_type(<<"1">>) -> add;
cmd_type(<<"3">>) -> delete;
cmd_type(_) -> unknown_cmd_type.

handle_redis_psk_event(add, PskID, PSK) ->
    logger:debug("storing psk: ~p", [{PskID, PSK}]),
    ets:insert(?PSK_CACHE, {PskID, PSK});
handle_redis_psk_event(delete, PskID, _PSK) ->
    logger:debug("remove psk: ~p from cache", [{PskID, _PSK}]),
    ets:delete(?PSK_CACHE, PskID);
handle_redis_psk_event(unknown_cmd_type, _PskID, _PSK) ->
    logger:error("~p, unknown cmd-type", [?FUNCTION_NAME]).
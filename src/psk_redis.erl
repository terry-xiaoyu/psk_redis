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

-export([ start_link/0
        , psk_lookup/3
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {}).

-define(PSK_CACHE, coaproxy_psk_cache).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% TO DO: make this module as a dependency of coaproxy
psk_lookup(psk, ClientPSKID, _PskState) ->
    case from_cache(ClientPSKID) of
        not_found ->
            from_redis(ClientPSKID);
        PSK -> {ok, PSK}
    end.

from_redis(ClientPSKID) ->
    case query_redis(ClientPSKID) of
        not_found -> error;
        PSK -> {ok, PSK}
    end.

%% Read from a Redis Hash
query_redis(_ClientPSKID) ->
    not_found.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ets:new(?PSK_CACHE, [set, public, named_table, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

from_cache(ClientPSKID) ->
    case ets:lookup(?PSK_CACHE, ClientPSKID) of
        [{_K, PSK}] ->
            logger:debug("lookup for psk_id: ~p, found psk: ~p", [ClientPSKID, PSK]),
            PSK;
        [] ->
            not_found
    end.


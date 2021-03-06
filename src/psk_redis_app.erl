%%%-------------------------------------------------------------------
%% @doc psk_redis public API
%% @end
%%%-------------------------------------------------------------------

-module(psk_redis_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    psk_redis_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

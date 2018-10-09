%%%-------------------------------------------------------------------
%% @doc psk_redis top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(psk_redis_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, { #{strategy => one_for_one,
             intensity => 5,
             period => 10}, [psk_cache_spec()]}}.

%%====================================================================
%% Internal functions
%%====================================================================

psk_cache_spec() ->
    #{id => psk_redis,
      start => {psk_redis, start_link, []},
      restart => transient,
      shutdown => 3000,
      type => worker,
      modules => [psk_redis]}.
-module(psk_http).

-export([request/4, request/5]).

request(Method, URL, Headers, Body) ->
    request(Method, URL, Headers, Body, 3).

request(_Method, URL, _Headers, _Body, _RetryCount = 0) ->
    lager:error("psk_redis http timeout, max retry count reached, URL: ~p", [URL]),
    {error, timeout};
request(Method, URL, Headers, Body, RetryCount) ->
    Opts = [{pool, default},
            {connect_timeout, 10000}, %% timeout used when establishing the TCP connections
            {recv_timeout, 30000},    %% timeout used when waiting for responses from peer
            {timeout, 150000}, %% how long the connection will be kept in the pool before dropped
            {follow_redirect, true},
            {max_redirect, 5}],
    case timer:tc(hackney, Method, [URL, Headers, Body, Opts]) of
        {RTT, {error, timeout}} ->
            logger:warning("psk_redis http try again... used ~pms, Method: ~p, Url: ~p, ReqBody: ~p",
                [ms(RTT), Method, URL, Body]),
            request(Method, URL, Headers, Body, RetryCount-1);
        {RTT, {error, Reason}} ->
            logger:error("psk_redis http error: ~p, used ~pms, Method: ~p, Url: ~p, ReqBody: ~p",
                [Reason, ms(RTT), Method, URL, Body]),
            {error, Reason};
        {RTT, {ok, Code, _ResHeaders, Client}} ->
            {ok, ResBody} = hackney:body(Client),
            logger:debug("psk_redis http received ~p in ~pms, StatusCode: ~p, Method: ~p, Url: ~p, ReqBody: ~p",
                [ResBody, ms(RTT), Code, Method, URL, Body]),
            {ok, Code, ResBody}
    end.

ms(MicroSeconds) -> MicroSeconds / 1000.
%% Copyright 2018 Erlio GmbH Basel Switzerland (http://erl.io)
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

-module(vmq_status_http).
-behaviour(vmq_http_config).

-export([routes/0]).
-export([node_status/0]).
-export([init/3,
         handle/2,
         terminate/3]).

routes() ->
    [{"/status.json", ?MODULE, []},
     {"/status", cowboy_static, {priv_file, vmq_server, "static/index.html"}},
     {"/status/[...]", cowboy_static, {priv_dir, vmq_server, "static"}}].

init(_Type, Req, _Opts) ->
    {ok, Req, undefined}.

handle(Req, State) ->
    {ContentType, Req2} = cowboy_req:header(<<"content-type">>, Req,
                                            <<"application/json">>),
    {ok, reply(Req2, ContentType), State}.

terminate(_Reason, _Req, _State) ->
    ok.

reply(Req, <<"application/json">>) ->
    Output = cluster_status(),
    {ok, Req2} = cowboy_req:reply(200, [{<<"content-type">>, <<"application/json">>}],
                                  Output, Req),
    Req2.

cluster_status() ->
    Nodes0 = nodes(),
    {Result0, _BadNodes} = rpc:multicall(Nodes0, ?MODULE, node_status, []),
    Result1 = [{R, N} || {{ok, R}, N} <- lists:zip(Result0, Nodes0)],
    {Result2, Nodes1} = lists:unzip(Result1),
    {ok, MyStatus} = node_status(),
    Data = [{atom_to_binary(Node, utf8), NodeResult} || {Node, NodeResult} <- lists:zip([node() | Nodes1], [MyStatus | Result2])],
    lager:info("cluster status ~p~n", [Data]),
    jsx:encode(Data).


node_status() ->
    % Total Connections
    counter_val('socket_open'),
    SocketOpen = counter_val('socket_open'),
    SocketClose = counter_val('socket_close'),
    TotalConnections = SocketOpen - SocketClose,
    % Total Online Queues
    TotalQueues = vmq_queue_sup_sup:nr_of_queues(),
    TotalOfflineQueues = TotalQueues - TotalConnections,
    % Total Publishes In
    TotalPublishIn = counter_val('mqtt_publish_received'),
    TotalPublishOut = counter_val('mqtt_publish_sent'),
    TotalQueueIn = counter_val('queue_in'),
    TotalQueueOut = counter_val('queue_out'),
    TotalQueueDrop = counter_val('queue_drop'),
    TotalQueueUnhandled = counter_val('queue_unhandled'),
    {NrOfSubs, _SMemory} = vmq_reg_trie:stats(),
    {NrOfRetain, _RMemory} = vmq_retain_srv:stats(),
    {ok, [
     {<<"num_online">>, TotalConnections},
     {<<"num_offline">>, TotalOfflineQueues},
     {<<"msg_in">>, TotalPublishIn},
     {<<"msg_out">>, TotalPublishOut},
     {<<"queue_in">>, TotalQueueIn},
     {<<"queue_out">>, TotalQueueOut},
     {<<"queue_drop">>, TotalQueueDrop},
     {<<"queue_unhandled">>, TotalQueueUnhandled},
     {<<"num_subscriptions">>, NrOfSubs},
     {<<"num_retained">>, NrOfRetain},
     {<<"mystatus">>, [{atom_to_binary(Node, utf8), Status} || {Node, Status} <- vmq_cluster:status()]},
     {<<"listeners">>, listeners()},
     {<<"version">>, version()}]}.

counter_val(C) ->
    try vmq_metrics:counter_val(C) of
        Value -> Value
    catch
        _:_ -> 0
    end.

listeners() ->
    lists:foldl(
      fun({Type, Ip, Port, Status, MP, MaxConns}, Acc) ->
              [[{type, Type}, {status, Status}, {ip, list_to_binary(Ip)},
                {port, list_to_integer(Port)}, {mountpoint, MP}, {max_conns, MaxConns}]
               |Acc]
      end, [], vmq_ranch_config:listeners()).

version() ->
    case release_handler:which_releases(current) of
        [{"vernemq", Version, _, current}|_] ->
            list_to_binary(Version);
        [] ->
            [{"vernemq", Version, _, permanent}|_] = release_handler:which_releases(permanent),
            list_to_binary(Version)
    end.
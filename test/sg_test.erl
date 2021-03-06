-module(sg_test).
-compile(export_all).

test() ->
    {ok, Server} = sg_server:start(nil),
    sg_server:put(0, [{type, 0}]),
    join_test(),
    io:format("get: ~p~n", [sg_server:get({type, 10}, {type, 15}, [type])]),
    timer:sleep(infinity).

join_test() ->
    join_test(1, 100).

join_test(N, N) ->
    ok;
join_test(N, M) ->
    sg_server:put(N, [{type, N}, {type2,N}]),
    timer:sleep(10),
    join_test(N + 1, M).


get_test() ->
    A = sg_server:get(13),
    B = sg_server:get(30, 50),
    C = sg_server:get(0, 20),
    {A, B, C}.


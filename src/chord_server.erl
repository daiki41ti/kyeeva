
%% TODO successor-list の更新処理の実装

-module(chord_server).
-behaviour(gen_server).

-include("../include/common_chord.hrl").

%% API
-export([start/0,
        start/1,
        get/1,
        put/2,
        call/4,
        server/0]).

%% spawned functions
-export([lookup_op/2]).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).


%%====================================================================
%% API
%%====================================================================
start() ->
    start(nil).

start(InitNode) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [InitNode], []).


get(Key) ->
    case gen_server:call(?MODULE, {lookup_op, Key}) of
        {_, Pair={Key, _, _}} -> [Pair];
        {_, {error, {not_found, _}}} -> []
    end.


put(Key, Value) ->
    put(?MODULE, Key, Value).

put(Server, Key, Value) ->
    {SelectedServer, _} = gen_server:call(Server, {lookup_op, Key}),
    case gen_server:call(SelectedServer, {put_op, Key, Value}) of
        {error, not_me} -> put(SelectedServer, Key, Value);
        true            -> true
    end.


call(Key, ModuleName, FuncName, Args) ->
    call(?MODULE, Key, ModuleName, FuncName, Args).

call(Server, Key, ModuleName, FuncName, Args) ->
    {SelectedServer, _} = gen_server:call(Server, {lookup_op, Key}),
    case gen_server:call(SelectedServer, {call_op, Key, ModuleName, FuncName, Args}) of
        {error, not_me} -> call(SelectedServer, Key, ModuleName, FuncName, Args);
        Any             -> Any
    end.


server() ->
    {ok, whereis(?MODULE)}.


%%====================================================================
%% gen_server callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([nil]) ->
    MyHash = myhash(),
    {ok, Store} = store_server:start(),
    {ok, Manager} = chord_man:start(MyHash, #succlist{bigger=[], smaller=[]}),
    {ok, #state{myhash=MyHash, manager=Manager, store=Store}};
init([InitNode]) ->
    case net_adm:ping(InitNode) of
        pong -> {ok, init_successor_list(InitNode)};
        pang -> {error, {not_found, InitNode}}
    end.

init_successor_list(InitNode) ->
    case rpc:call(InitNode, ?MODULE, server, []) of
        {badrpc, Reason} -> {stop, Reason};
        {ok, InitServer} ->
            MyHash = myhash(),
            Store = store_server:start(),
            {InitSuccList, DataList} = gen_server:call(InitServer, {join_op, MyHash}),
            Manager = chord_man:start(MyHash, InitSuccList),
            [store_server:put(Key, Value, Hash) || {Key, Value, Hash} <- DataList],
            #state{myhash=MyHash, manager=Manager, store=Store}
    end.
head({succlist, [], []}) ->
    nil;
head({succlist, [{_, Hash} | _], []}) ->
    Hash;
head({succlist, _, [{_, Hash} | _]}) ->
    Hash.

myhash() ->
    crypto:start(),
    crypto:sha_init(),
    crypto:sha(term_to_binary(node())).


%%--------------------------------------------------------------------
%% Function: handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                                {reply, Reply, State, Timeout} |
%%                                                {noreply, State} |
%%                                                {noreply, State, Timeout} |
%%                                                {stop, Reason, Reply, State} |
%%                                                {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({join_op, NewHash}, From, State) ->
    join_op(NewHash, From, State#state.myhash),
    {noreply, State};

handle_call({lookup_op, Key}, From, State) ->
    spawn(?MODULE, lookup_op, [Key, From]),
    {noreply, State};

handle_call({put_op, Key, Value}, _, State) ->
    {reply, put_op(Key, Value), State};

handle_call({call_op, Key, Module, Func, Args}, _, State) ->
    {reply, call_op(Key, Module, Func, Args), State};

handle_call(_, _, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({join_op_cast, NewHash, From}, State) ->
    join_op(NewHash, From, State#state.myhash),
    {noreply, State};

handle_cast({lookup_op_cast, Key, From}, State) ->
    spawn(?MODULE, lookup_op, [Key, From]),
    {noreply, State};

handle_cast(_, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_, _) ->
    ok.


%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_, State, _) ->
    {ok, State}.


%%====================================================================
%% called by handle_call/3
%%====================================================================
%%--------------------------------------------------------------------
%% join operation
%%--------------------------------------------------------------------
join_op(NewHash, From, MyHash) ->
    MySuccList = chord_man:successor(1),
    case chord_man:find(1, NewHash) of
        self -> join_op_1(MyHash, NewHash, From, MySuccList);
        {OtherServer, _} ->
            gen_server:cast(OtherServer, {join_op_cast, NewHash, From}),
            MySuccList
    end.

join_op_1(MyHash, NewHash, From, MySuccList) ->
    ResultSuccList = case MySuccList of
        {_, [], []} when MyHash < NewHash -> MySuccList#succlist{smaller=[{self(), MyHash}]};
        {_, [], []} when MyHash > NewHash -> MySuccList#succlist{bigger=[{self(), MyHash}]};
        _ when MyHash > NewHash ->
            {Smaller1, Bigger1} = lists:partition(fun(X) -> X < NewHash end, MySuccList#succlist.smaller),
            Smaller = cut(?LENGTH_SUCCESSOR_LIST, Smaller1),
            Bigger = cut(?LENGTH_SUCCESSOR_LIST - length(Smaller), Bigger1 ++ MySuccList#succlist.bigger),
            case Bigger of
                [] -> #succlist{smaller=cut(length(Smaller) - 1, Smaller), bigger=[{self(), MyHash}]};
                _ -> #succlist{smaller=Smaller, bigger=Bigger}
            end;
        _ -> MySuccList
    end,
    gen_server:reply(From, {ResultSuccList, R=store_server:range(NewHash, MyHash)}),
    join_op_2(MyHash, NewHash, From, MySuccList).

join_op_2(MyHash, NewHash, {NewServer, _Ref}, MySuccList) when MyHash < NewHash ->
    {Bigger, _} = if
        length(MySuccList#succlist.smaller) + length(MySuccList#succlist.bigger) < ?LENGTH_SUCCESSOR_LIST -> {MySuccList#succlist.bigger, []};
        true -> lists:split(?LENGTH_SUCCESSOR_LIST - length(MySuccList#succlist.smaller) - 1, MySuccList#succlist.bigger)
    end,
    chord_man:set(1, MySuccList#succlist{bigger = [{NewServer, NewHash} | Bigger]});
join_op_2(MyHash, NewHash, {NewServer, _Ref}, MySuccList) when MyHash > NewHash ->
    {Smaller, _} = if
        length(MySuccList#succlist.smaller) + length(MySuccList#succlist.bigger) < ?LENGTH_SUCCESSOR_LIST -> {MySuccList#succlist.bigger, []};
        true -> lists:split(?LENGTH_SUCCESSOR_LIST - length(MySuccList#succlist.bigger) - 1, MySuccList#succlist.smaller)
    end,
    chord_man:set(1, MySuccList#succlist{smaller = [{NewServer, NewHash} | Smaller]}).


%%--------------------------------------------------------------------
%% lookup operation
%%--------------------------------------------------------------------
%% spawned funtion
lookup_op(Key, From) ->
    Hash = crypto:sha(term_to_binary(Key)),
    case chord_man:find(1, Hash) of
        self   -> lookup_op_1(Key, From);
        {S, _} -> gen_server:cast(S, {lookup_op_cast, Key, From})
    end.

lookup_op_1(Key, From) ->
    case store_server:get(Key) of
        [] -> gen_server:reply(From, {whereis(?MODULE), {error, {not_found, Key}}});    %% TODO: add exception handling for not_found pattern
        [{Key, Value, Hash}] -> gen_server:reply(From, {whereis(?MODULE), {Key, Value, Hash}})
    end.


%%--------------------------------------------------------------------
%% put operation
%%--------------------------------------------------------------------
put_op(Key, Value) ->
    Hash = crypto:sha(term_to_binary(Key)),
    case chord_man:find(1, Hash) of
        self -> store_server:put(Key, Value);
        _    -> {error, not_me}
    end.


%%--------------------------------------------------------------------
%% put operation
%%--------------------------------------------------------------------
call_op(Key, Module, Func, Args) ->
    Hash = crypto:sha(term_to_binary(Key)),
    case chord_man:find(1, Hash) of
        self -> apply(Module, Func, Args);
        _    -> {error, not_me}
    end.


%%====================================================================
%% utilities
%%====================================================================
cut(Len, List) when length(List) =< Len->
    List;
cut(Len, List) ->
    {List1, _} = lists:split(Len, List),
    List1.

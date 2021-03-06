-module(ai_balance_pool).

-export([start_link/0, init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2]).
-export([least_busy/1,rand/1,join/2]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(name() :: term()).

-spec(start_link/0 :: () -> {'ok', pid()} | {'error', any()}).
-spec(start/0 :: () -> {'ok', pid()} | {'error', any()}).
-spec(join/2 :: (name(), pid()) -> 'ok').
-spec(leave/2 :: (name(), pid()) -> 'ok').
-spec(get_members/1 :: (name()) -> [pid()]).

-endif.

%%----------------------------------------------------------------------------


%%%
%%% Exported functions
%%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


join(Name, Pid) when is_pid(Pid) ->
    gen_server:cast(?MODULE, {join, Name, Pid}).

least_busy(Name) ->
    Members  = group_members(Name),
    ai_process:least_busy(Members).
rand(Name)->
    case group_members(Name) of
        [] -> {error, empty_process_group};
        Members ->
            {_,_,X} = os:timestamp(),
            {ok,lists:nth((X rem length(Members))+1, Members)}
    end.

%%%
%%% Callback functions from gen_server
%%%

-record(state, {}).

init([]) ->
    ai_balance_pool = ets:new(ai_balance_pool, [ordered_set, 
        protected, named_table, {write_concurrency,false},{read_concurrency,true}]),
    {ok, #state{}}.

handle_call(sync, _From, S) ->
    {reply, ok, S};

handle_call(Request, From, S) ->
    error_logger:warning_msg("The ai_pool server received an unexpected message:\n"
                             "handle_call(~p, ~p, _)\n", 
                             [Request, From]),
    {noreply, S}.

handle_cast({join, Name, Pid}, S) ->
    join_group(Name, Pid),
    {noreply, S};

handle_cast(_, S) ->
    {noreply, S}.

handle_info({'DOWN', MonitorRef, process, _Pid, _Info}, S) ->
    member_died(MonitorRef),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    true = ets:delete(ai_balance_pool),
    ok.

%%%
%%% Local functions
%%%

%%% One ETS table, ai_balance_pool, is used for bookkeeping. The type of the
%%% table is ordered_set, and the fast matching of partially
%%% instantiated keys is used extensively.
%%%
%%% {{ref, Pid}, MonitorRef, Counter}
%%% {{ref, MonitorRef}, Pid}
%%%    Each process has one monitor. Counter is incremented when the
%%%    Pid joins some group.
%%% {{member, Name, Pid}, _}
%%%    Pid is a member of group Name, GroupCounter is incremented when the
%%%    Pid joins the group Name.
%%% {{pid, Pid, Name}}
%%%    Pid is a member of group Name.

member_died(Ref) ->
    [{{ref, Ref}, Pid}] = ets:lookup(ai_balance_pool, {ref, Ref}),
    Names = member_groups(Pid),
    _ = [leave_group(Name, P) || 
            Name <- Names,
            P <- member_in_group(Pid, Name)],
    ok.
%% 先监控，再进入组
join_group(Name, Pid) ->
    Ref_Pid = {ref, Pid}, 
	%% 先尝试 +1 如果 +1 失败
	%% 说明pid不在ets表中，那么需要先Monitor再添加
    try _ = ets:update_counter(ai_balance_pool, Ref_Pid, {3, +1})
    catch _:_ ->
            Ref = erlang:monitor(process, Pid),
            true = ets:insert(ai_balance_pool, {Ref_Pid, Ref, 1}),
            true = ets:insert(ai_balance_pool, {{ref, Ref}, Pid})
    end,
    Member_Name_Pid = {member, Name, Pid},
    try _ = ets:update_counter(ai_balance_pool, Member_Name_Pid, {2, +1})
    catch _:_ ->
            true = ets:insert(ai_balance_pool, {Member_Name_Pid, 1}),
            true = ets:insert(ai_balance_pool, {{pid, Pid, Name}})
    end.
%% 先退组,再退监控
leave_group(Name, Pid) ->
    Member_Name_Pid = {member, Name, Pid},
		%% 先减少1
    try ets:update_counter(ai_balance_pool, Member_Name_Pid, {2, -1}) of
        N ->
            if 
                N =:= 0 ->
										%% 到0了，那么我们就删掉表项
                    true = ets:delete(ai_balance_pool, {pid, Pid, Name}),
                    true = ets:delete(ai_balance_pool, Member_Name_Pid);
                true ->
                    ok
            end,
            Ref_Pid = {ref, Pid}, 
            case ets:update_counter(ai_balance_pool, Ref_Pid, {3, -1}) of
                0 ->
                    [{Ref_Pid,Ref,0}] = ets:lookup(ai_balance_pool, Ref_Pid),
                    true = ets:delete(ai_balance_pool, {ref, Ref}),
                    true = ets:delete(ai_balance_pool, Ref_Pid),
                    true = erlang:demonitor(Ref, [flush]),
                    ok;
                _ ->
                    ok
            end
    catch _:_ ->
            ok
    end.
%% 直接从表中找
group_members(Name) ->
    [P || 
        [P, N] <- ets:match(ai_balance_pool, {{member, Name, '$1'},'$2'}),
        _ <- lists:seq(1, N)].

member_in_group(Pid, Name) ->
    [{{member, Name, Pid}, N}] = ets:lookup(ai_balance_pool, {member, Name, Pid}),
    lists:duplicate(N, Pid).


member_groups(Pid) ->
    [Name || [Name] <- ets:match(ai_balance_pool, {{pid, Pid, '$1'}})].

%%%-------------------------------------------------------------------
%%% @author  <david@laptop-02.local>
%%% @copyright (C) 2018, 
%%% @doc
%%%
%%% @end
%%% Created :  6 Nov 2018 by  <david@laptop-02.local>
%%%-------------------------------------------------------------------
-module(ai_mutex).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3, format_status/2]).

-export([mutex/0,mutex/1,destroy/1]).
-export([try_lock/1,lock/1,release/1]).
-export([cond_lock/2,cond_release/2]).

-define(SUFFIX, "_ai_mutex").
-define(SERVER, ?MODULE).

-record(state, {	
	waiters :: queue:queue(),
	waiters_map :: maps:maps(),
	locker :: undefined | pid(),
	monitors :: maps:maps()
}).

%%%===================================================================
%%% API
%%%===================================================================
-spec mutex()-> {ok,pid()}.
mutex()->
	Opts = [],
	ai_mutex_sup:mutex(Opts).
-spec mutex(Name :: atom())-> {ok,pid()}.
mutex(Name)->
    Opts = [{name,ai_strings:atom_suffix(Name,?SUFFIX,false)}],
    ai_mutex_sup:mutex(Opts).
-spec destroy(Mutex :: atom()|pid()) -> ok.
destroy(Mutex) when is_pid(Mutex)->
    gen_server:cast(Mutex,destroy);
destroy(Mutex) ->
	gen_server:cast(server_name(Mutex),destroy).
	
-spec lock(Mutex :: pid()| atom()) -> 
	ok | {error,already_lock} | destroy.
lock(Mutex) when erlang:is_pid(Mutex)->
    do_lock(Mutex);
lock(Mutex) ->
    do_lock(server_name(Mutex)).
-spec do_lock(Mutex :: pid()| atom()) -> 
	ok | {error,already_lock} | destroy.
do_lock(Mutex)->
    Caller = self(),
    gen_server:call(Mutex,{lock,Caller},infinity).

-spec try_lock(Mutex :: pid() | atom()) -> ok.
try_lock(Mutex) when erlang:is_pid(Mutex) ->
	do_try_lock(Mutex);
try_lock(Mutex) ->
	do_try_lock(server_name(Mutex)).
-spec do_try_lock(Mutex :: pid() | atom())-> ok | {error,locked}.
do_try_lock(Mutex)->
	Caller = self(),
	gen_server:call(Mutex,{try_lock,Caller}).

-spec release(Mutex :: atom() | pid()) -> ok.
release(Mutex) when erlang:is_pid(Mutex)->
    do_release(Mutex);
release(Mutex) ->
    do_release(server_name(Mutex)).
-spec do_release(Mutex :: atom() | pid()) -> ok.
do_release(Mutex)->
	Caller = self(),
	gen_server:cast(Mutex,{release,Caller}).
-spec cond_release(Mutex :: atom() | pid(),Locker :: pid()) -> ok.
cond_release(Mutex,Locker) when erlang:is_pid(Mutex)->
	do_cond_release(Mutex,Locker);
cond_release(Mutex,Locker)->
	do_cond_release(server_name(Mutex),Locker).
-spec do_cond_release(Mutex :: atom() | pid(),Locker :: pid()) -> ok.
do_cond_release(Mutex,Locker)->
	gen_server:call(Mutex,{cond_release,Locker},infinity).
-spec cond_lock(Mutex :: atom()| pid(),Locker :: pid())-> ok | destroy.
cond_lock(Mutex,Locker) when erlang:is_pid(Mutex) ->
	do_cond_lock(Mutex,Locker);
cond_lock(Mutex,Locker) ->
	do_cond_lock(server_name(Mutex),Locker).
-spec do_cond_lock(Mutex :: atom() | pid(), Locker :: pid())-> ok | destroy.
do_cond_lock(Mutex,Locker)->
	Caller = self(),
	gen_server:call(Mutex,{cond_lock,Caller,Locker},infinity).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(Opts :: proplists:proplists()) -> {ok, Pid :: pid()} |
	{error, Error :: {already_started, pid()}} |
	{error, Error :: term()} |
	ignore.
start_link(Opts) ->
    Name = proplists:get_value(name,Opts),
    case Name of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        _ -> start_link(Name,proplists:delete(name, Opts))
    end.

-spec start_link(Name :: atom(),Opts :: proplists:proplists()) -> {ok, Pid :: pid()} |
											{error, Error :: {already_started, pid()}} |
											{error, Error :: term()} |
											ignore.
start_link(Name,Opts) ->
	gen_server:start_link({local,Name}, ?MODULE, Opts, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
	{ok, State :: term(), Timeout :: timeout()} |
	{ok, State :: term(), hibernate} |
	{stop, Reason :: term()} |
	ignore.
init(_Opts) ->
	{ok, #state{ 
		waiters = queue:new(),
		waiters_map = maps:new(),
		locker = undefined,
		monitors = maps:new()
	}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
	{reply, Reply :: term(), NewState :: term()} |
	{reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
	{reply, Reply :: term(), NewState :: term(), hibernate} |
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), Timeout :: timeout()} |
	{noreply, NewState :: term(), hibernate} |
	{stop, Reason :: term(), Reply :: term(), NewState :: term()} |
	{stop, Reason :: term(), NewState :: term()}.
handle_call({lock,Caller},_From,#state{locker = undefined} = State)->
	{Result,NewState} = lock_mutex(Caller,State),
	{reply,Result,NewState};
handle_call({lock,Caller},_From,#state{locker = Caller} = State)->
	{reply,{error,already_lock},State};
handle_call({lock,Caller},From,State)->
    NewState = wait_mutex(Caller,{lock,From},State),
	{noreply,NewState};
handle_call({try_lock,Caller},_From,#state{locker = undefined} = State)->
	{Result,NewState} = lock_mutex(Caller,State),
	{reply,Result,NewState};
handle_call({try_lock,Caller},_From,#state{locker = L } = State)->
	if 
		L == Caller -> {reply,{error,already_lock},State};
		true -> {reply,{error,locked},State}
	end;
handle_call({cond_lock,Caller,Locker},From,#state{locker = L } = State)->
	case L of 
		Locker -> {reply,{error,already_lock},State};
		undefined -> 
			{Result,NewState} = lock_mutex(Locker,State),
			{reply,Result,NewState};
		_ ->
			NewState = wait_mutex(Locker,{cond_lock,Caller,From},State),
			{noreply,NewState}
	end;
handle_call({cond_release,Locker},_From,#state{locker = L } = State)->
	if 
		L == Locker -> 
			NewState = release_mutex(Locker,State),
			{reply,ok,NewState};
		true ->
			{reply,{error,locked},State}
	end;
handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), Timeout :: timeout()} |
	{noreply, NewState :: term(), hibernate} |
	{stop, Reason :: term(), NewState :: term()}.
handle_cast({release,Caller},#state{locker = Caller} = State)->
	NewState = release_mutex(Caller,State),
	{noreply, NewState};
handle_cast(destroy,#state{waiters = W,locker = L} =State)->
    NewState = destroy_mutex(queue:to_list(W),L,State),
    {stop,destroy,NewState#state{waiters = queue:new()}};
handle_cast(_Request, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
	{noreply, NewState :: term()} |
	{noreply, NewState :: term(), Timeout :: timeout()} |
	{noreply, NewState :: term(), hibernate} |
	{stop, Reason :: normal | term(), NewState :: term()}.
handle_info({'DOWN', _MonitorReference, process, Pid,_Reason},State)->
    NewState = processor_down(Pid,State),
    {noreply,NewState};
handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
	State :: term()) -> any().
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
	State :: term(),
	Extra :: term()) -> {ok, NewState :: term()} |
	{error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
	Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
	Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
server_name(Mutex) -> ai_strings:atom_suffix(Mutex,?SUFFIX,true).

lock_mutex(Locker,#state{monitors = M} =  State)->
	M2 = ai_process:monitor_process(Locker,M),
	{ok,State#state{ locker = Locker, monitors = M2}}.
wait_mutex(Locker,From,#state{waiters = W, waiters_map = WM, monitors = M} = State)->
	M2 = ai_process:monitor_process(Locker,M),
	State#state{
		waiters = queue:in(Locker,W),
		waiters_map = maps:put(Locker,From,WM),
		monitors = M2
	}.
remove_waiter(Locker,#state{waiters = W,waiters_map = WM,monitors = M} = State)->
	M2 = ai_process:demonitor_process(Locker,M),
	From= maps:get(Locker,WM),
	reply(From,{error,locker_down},true),
    State#state{
        waiters = queue:filter(fun(I)-> I /= Locker end,W),
        waiters_map = maps:remove(Locker,WM),
        monitors = M2
    }.


processor_down(Pid,#state{waiters = W,locker = L} = State)->
    case queue:member(Pid,W) of
        true -> remove_waiter(Pid,State);
        _ ->
			if 
				L == Pid -> release_mutex(Pid,State);
				true -> State
			end 
	end.
release_mutex(Locker,#state{waiters = W,monitors = M} = State)->
	M2 = ai_process:demonitor_process(Locker,M),
	notify_waiters(W,State#state{locker = undefined,monitors = M2}).
		
notify_waiters(Q,State) ->
	case queue:out(Q) of
		{{value, Waiter}, Q2}-> notify_waiter(Waiter,Q2,State);
		{empty,Q} -> State
	end.
notify_waiter(Caller,Q2,#state{waiters_map = WM,monitors = M } = State) ->
	%% 某个进程崩溃信息可能晚于mutex释放的时间
	case erlang:is_process_alive(Caller) of
		true ->
			From = maps:get(Caller,WM),
			reply(From,ok,false),
			State#state{
				waiters = Q2,
				waiters_map = maps:remove(Caller,WM),
				locker = Caller
			};
		_ ->
			M2 = ai_process:demonitor(Caller,M),
			From = maps:get(Caller,WM),
			reply(From,{error,locker_down},true),
			notify_waiters(Q2,State#state{
								waiters = Q2,
								waiters_map = maps:remove(Caller,WM),
								monitors = M2})
	end.

destroy_mutex(Waiters,Locker,State)->
	State1 = destroy_waiters(Waiters,State),
	#state{monitors = M} = State1,
	M2 = ai_process:demonitor_process(Locker,M),
	State#state{locker = undefined,monitors = M2}.
destroy_waiters([],State)-> State;
destroy_waiters([H|T],#state{waiters_map = WM, monitors = M } = State)->
	From = maps:get(H,WM),
	M2 = ai_process:demonitor_process(H,M),
	reply(From,ok,destroy),
	destroy_waiters(T,State#state{waiters_map = maps:remove(H,WM),monitors = M2}).
		
reply({lock,From},Msg,Cond)->
	case Cond of 
		true -> ok;
		_->gen_server:reply(From,Msg)
	end;
reply({cond_lock,Caller,From},Msg,_Cond)->
	case erlang:is_process_alive(Caller) of 
		true -> gen_server:reply(From,Msg);
		false -> ok 
	end.
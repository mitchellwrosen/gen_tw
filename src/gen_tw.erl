-module(gen_tw).

%% API
-export([spawn/2,
         spawn_link/2,
         stop/1,
         stop/2,
         gvt/2,
         event/2,
         event/3,
         antievent/1,
         notify/2,
         rollback/2,
         uuid/0
        ]).

-export_type([ref/0, event/0, virtual_time/0]).

-export([init/4]).

-callback init(Arg::term()) -> {ok, InitialState::term()} | {error, Reason::term()}.

-callback tick_tock(CurrentLVT::virtual_time(), State::term()) -> {NextLVT::virtual_time(), NextState::term()}.
-callback handle_event(CurrentLVT::virtual_time(), EventLVT::virtual_time(), Event::term(), ModuleState::term()) ->
    {ok, NextState::term()} |
    {error, Reason::term()}.
-callback terminate(State::term()) -> any().

-record(event,
    {lvt      :: virtual_time(),    %% Simulation time the event is to be applied
     id       :: uuid:uuid(),       %% Unique identifier for the event
     not_anti :: boolean(),         %% true for event, false for antievent
     link     :: ref() | undefined, %% Causal link for the event (Pid)
     payload  :: term()             %% Event payload
    }).

%% Invariant: The list contains no duplicates, and the events are sorted by
%% increasing LVT.
-type event_list() :: [#event{}].

%% Invariant: The list contains no duplicates, and the events are sorted by
%% decreasing LVT.
-type past_event_list() :: [#event{}].

-type module_state() :: {virtual_time(), term()}.

%% List of past states of client module.
%%
%% Invariant: The LVTs are unique and sorted in descending order.
-type module_state_list() :: [module_state()].

-opaque ref() :: pid().
-opaque event() :: #event{}.
-type virtual_time() :: integer().

-define(STOP_PAYLOAD(Reason), {'$stop', Reason}).
-define(GVT_UPDATE_PAYLOAD, '$gvt').

%%%===================================================================
%%% API
%%%===================================================================

-spec spawn(atom(), term()) -> {ok, ref()}.
spawn(Module, Arg) ->
    Pid = proc_lib:spawn(?MODULE, init, [self(), 0, Module, Arg]),
    {ok, Pid}.

-spec spawn_link(atom(), term()) -> {ok, ref()}.
spawn_link(Module, Arg) ->
    Pid = proc_lib:spawn_link(?MODULE, init, [self(), 0, Module, Arg]),
    {ok, Pid}.

-spec stop(ref()) -> ok.
stop(Pid) ->
    stop(Pid, normal).

-spec stop(ref(), term()) -> ok.
stop(Pid, Reason) ->
    notify(Pid, event(undefined, ?STOP_PAYLOAD(Reason))).

-spec gvt(ref(), integer()) -> ok.
gvt(Pid, GVT) when is_integer(GVT) andalso GVT >= 0 ->
    notify(Pid, event(GVT, ?GVT_UPDATE_PAYLOAD)).

-spec antievent(Event::event()) -> event().
antievent(Event=#event{}) ->
    Event#event{
        not_anti = false,
        link = undefined
    }.

-spec event(virtual_time(), term()) -> event().
event(LVT, Payload) ->
    event(undefined, LVT, Payload).

-spec event(ref() | undefined, virtual_time(), term()) -> event().
event(Link, LVT, Payload) ->
    #event{
        lvt      = LVT,
        id       = uuid(),
        not_anti = true,
        link     = Link,
        payload  = Payload
    }.

-spec notify(ref(), event() | [event()]) -> ok.
notify(Ref, Events) when is_list(Events) ->
    Ref ! Events,
    ok;
notify(Ref, Event) when is_record(Event, event) ->
    notify(Ref, [Event]).

%%%===================================================================
%%% Internals
%%%===================================================================

-spec init(pid(), virtual_time(), atom(), term()) -> no_return().
init(Parent, InitialLVT, Module, Arg) ->
    case erlang:apply(Module, init, [Arg]) of
        {ok, ModuleState} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            loop(InitialLVT, [], [], Module, [{InitialLVT, ModuleState}]);

        Error ->
            exit(Error)
    end.

-spec drain_msgq(Events::event_list(), TMO::integer()) -> event_list().
drain_msgq(Events, TMO) ->
    receive
        NewEvents when is_list(NewEvents) ->
            drain_msgq(NewEvents ++ Events, 0);

        EventOrAntievent when is_record(EventOrAntievent, event) ->
            drain_msgq([EventOrAntievent | Events], 0);

        Msg ->
            error_logger:warning_msg("~p discarding msg: ~p~n", [?MODULE, Msg])

    after TMO ->
        ordsets:from_list(Events)
    end.

-spec drain_msgq(TMO::integer()) -> event_list().
drain_msgq(InitialTMO) ->
    drain_msgq([], InitialTMO).

-spec append_state(virtual_time(), term(), module_state_list()) -> module_state_list().
append_state(LVT, State, []) ->
    [{LVT, State}];
append_state(LVT, NewState, [{LVT, _OldState}|T]) ->
    [{LVT, NewState}|T];
append_state(NewLVT, NewState, OldStates = [{OldLVT, _}|_]) when NewLVT > OldLVT ->
    [{NewLVT, NewState}|OldStates].

-spec tick_tock(virtual_time(), atom(), term()) -> module_state().
tick_tock(LVT, Module, ModuleState) ->
    Module:tick_tock(LVT, ModuleState).

-spec loop(virtual_time(), event_list(), past_event_list(), atom(), module_state_list()) -> no_return().
%% No events to process, advance our local virtual time.
loop(LVT, _Events = [], PastEvents, Module, ModStates=[{LVT, ModState}|_]) ->
    case drain_msgq(0) of
        [] ->
            {NewLVT, NewModState} = tick_tock(LVT, Module, ModState),
            loop(NewLVT, [], PastEvents, Module, append_state(NewLVT, NewModState, ModStates));
        Events ->
            loop(LVT, Events, PastEvents, Module, ModStates)
    end;

loop(_LVT, _Events = [#event{payload=?STOP_PAYLOAD(Reason)}|_], _PastEvents, Module, [{_, ModState}|_]) ->
    Module:terminate(ModState),
    exit(Reason);

%% GVT Update.  We are guaranteed to never rollback to a time previous to this
%% time value, thus, we can safely garbage collect ModStates and PastEvents occuring
%% before GVT.
%%
%% NOTE:  We make no attempt to calculate GVT amongst gen_tw actors.  This is
%% the responsibility of a system higher up the application stack.
loop(LVT, _Events=[#event{lvt=GVT, payload=?GVT_UPDATE_PAYLOAD}|T], PastEvents, Module, ModStates) when LVT >= GVT ->
    NewModStates = [{ModLVT, ModState} || {ModLVT, ModState} <- ModStates, ModLVT >= GVT],
    NewPastEvents = [E || E<-PastEvents, E#event.lvt >= GVT],
    erlang:garbage_collect(),
    loop(LVT, T, NewPastEvents, Module, NewModStates);

%% First event in queue occurs before LVT.  Rollback to handle the event.
%%
%% Note:  This clause must applied before applying other rules such as
%% antievent/event cancellation.
loop(LVT, Events=[#event{lvt=ELVT}|_], PastEvents, Module, ModStates) when ELVT < LVT ->
    {ReplayOrUndo, NewPastEvents} = rollback(ELVT, PastEvents),

    {Replay, Undo} = lists:partition(fun(#event{link=Link}) -> Link == undefined end, ReplayOrUndo),

    %%Send antievents for all events that occured within (ELVT, LVT] that have
    %%a causal link.
    [begin
        Link = Event#event.link,
        Link ! antievent(Event)
     end || Event <- Undo],

    NewEvents = ordsets:union(Replay, Events),
    NewModStates = lists:dropwhile(fun({SLVT, _}) -> SLVT > ELVT end, ModStates),
    loop(ELVT, NewEvents, NewPastEvents, Module, NewModStates);

%% Antievent and events meeting in Events cancel each other
%% out.  Note:  We are relying on antievents appearing in the ordering first.
%% This prevents us from having to search PastEvents for the corresponding
%% event, in this case.
loop(LVT, [#event{id=EID, not_anti=false}|T], PastEvents, Module, ModStates) ->
    NewEvents = [E || E <- T, E#event.id /= EID],
    loop(LVT, NewEvents, PastEvents, Module, ModStates);

%% Event at or after the current value of LVT.  Process the event by invoking
%% Module:handle_event and looping on the new state provided.
%%
%% TODO:  We are currently halting on error here.  This is likely not what we
%% want to do.
loop(_LVT, [Event = #event{lvt=ELVT}|T], PastEvents, Module, ModStates=[{LVT, ModState}|_]) ->
    case handle_event(LVT, Event, Module, ModState) of
        {ok, NewModState} ->
            loop(ELVT, T, [Event|PastEvents], Module, append_state(ELVT, NewModState, ModStates));

        {error, Reason} ->
            %% TODO:  This can result in deadlock
            %% How can we more completely handle this?
            erlang:throw(Reason)
    end.

%% Partition past events into two lists: events othat occurred before the given
%% LVT, and events that occurred at or after the given LVT.
%%
%% e.g. if LVT = 2, [3,2,1,0] becomes {[1,0], [2,3]}
-spec rollback(virtual_time(), past_event_list(), event_list()) -> {event_list(), past_event_list()}.
rollback(_LVT, [], NewEvents) ->
    {NewEvents, []};
rollback(LVT, Events=[#event{lvt=ELVT}|_], NewEvents) when LVT > ELVT ->
    {NewEvents, Events};
rollback(LVT, [Event|T], NewEvents) ->
    rollback(LVT, T, [Event|NewEvents]).

-spec rollback(virtual_time(), past_event_list()) -> {event_list(), past_event_list()}.
rollback(LVT, Events) when is_integer(LVT) andalso LVT >= 0 ->
    rollback(LVT, Events, []).

handle_event(LVT, #event{lvt=EventLVT, payload=Payload}, Module, ModuleState) ->
    Module:handle_event(LVT, EventLVT, Payload, ModuleState).

-spec uuid() -> uuid:uuid().
uuid() ->
    uuid:uuid4().

%%%===================================================================
%%% Unit Tests
%%%===================================================================

-include_lib("eunit/include/eunit.hrl").

event_test() ->
    %% 2-ary event generates non-causal event
    E1 = event(0, <<"foo">>),
    ?assertEqual(E1#event.link, undefined),
    ?assertEqual(E1#event.lvt, 0),
    ?assertEqual(E1#event.payload, <<"foo">>),

    %% 3-ary event generates a causal event
    E2 = event(self(), 10, <<"bar">>),
    ?assertEqual(E2#event.link, self()),
    ?assertEqual(E2#event.lvt, 10),
    ?assertEqual(E2#event.payload, <<"bar">>).

%% Antievents are non-causal
antievent_test() ->
    E = event(self(), 150, <<"bar">>),
    A = antievent(E),

    ?assertEqual(A#event.not_anti, false),
    ?assertEqual(A#event.link, undefined).

append_state_test() ->
    T1 = append_state(0, foo, []),
    ?assertMatch(T1, [{0, foo}]),

    %% Latest states appear at the head of the list
    T2 = append_state(2, bar, T1),
    ?assertMatch([{2,bar} | T1], T2),

    %% Updating head element replaces the old value
    T3 = append_state(2, foobar, T2),
    ?assertMatch([{2,foobar}|T1], T3),

    %% Updating a value which is not the latest is not allowed
    try
        append_state(0, foobar, T2),
        ?assert(false)
    catch
        _:_ ->
            ok
    end.

rollback_test() ->
    InOrder = [event(LVT, <<>>) || LVT <- lists:seq(100,1, -1)],

    ?assertMatch({[], []}, rollback(0, [])),
    ?assertMatch({[], InOrder}, rollback(110, InOrder)),

    Temp = lists:reverse(InOrder),
    ?assertMatch({Temp, []}, rollback(0, InOrder)),

    {ResultReplay, ResultPast} = rollback(50, InOrder),
    ExpectedReplay = [E || E <- InOrder, E#event.lvt >= 50],
    ExpectedPast = [E || E <- InOrder, E#event.lvt < 50],

    ReplayDiff = ResultReplay -- ExpectedReplay,
    PastDiff = ResultPast -- ExpectedPast,

    ?assertMatch(ReplayDiff, []),
    ?assertMatch(PastDiff, []).

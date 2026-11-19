%%% The solver: what the program should do, written as lines, and varp's word
%%% on each -- in a pane of its own (csp_solve_wse, csp_solve_wx) beside the
%%% log and the chat.
%%%
%%% A line is a kind and a candyspeak condition about ONE CYCLE, as
%%% candyspeak_varp reads a reach: a name is what the cycle reads, X' what it
%%% leaves X at, rising() / falling() between two samples, A => B for !A || B.
%%%
%%%     assume     [LTE 1](K1, K2, K3)          holds in every cycle, taken
%%%     invariant  State == Night => !KitchenLight'     every cycle: proved, or
%%%                                                     a trace that breaks it
%%%     reach      State == Night && HallMotion         a run that gets there,
%%%                                                     or proved never
%%%
%%% `//' starts a comment; a blank line is nothing. The lines run in order,
%%% and an invariant proved holds for the lines after it: it is assumed
%%% there, which is what lets a later proof close (k-induction starts from
%%% any state; one the invariant rules out is not a start).
%%%
%%% A line with a trace is picked to show it: the panel gets {csp_solve,
%%% trace, T} and the code view walks it, replays it on csp. Closed, the
%%% panel gets {csp_solve, closed} and puts csp back as it was.
%%%
%%% Its own process, like the log and the chat: the lines live through every
%%% rebuild of the panel, which tells it the file to prove (file/2).

-module(csp_solve).

-export([start/2, file/2, toggle/1]).
-export([run/3, parse/1]).                      % the tests

-define(K, 10).
-define(KS, [1, 2, 5, 10, 20, 50]).
-define(TIMEOUT, 30).                           % seconds, each varp run

%% U is the pane's renderer, {Module, Handle}; Panel gets the traces.
start(U, Panel) ->
    spawn_link(fun() -> init(U, Panel) end).

%% The program the lines are about. What was found for the last one goes.
file(undefined, _File) -> ok;
file(S, File) -> S ! {file, File}, ok.

toggle(undefined) -> ok;
toggle(S) -> S ! toggle, ok.

init(U, Panel) ->
    Pane = cui(U, pane, ["solver", ?KS, ?K]),
    loop(#{ui => U, pane => Pane, panel => Panel, shown => false,
	   file => none, results => [], worker => none}).

cui({M, H}, F, A) -> apply(M, F, [H | A]).

pui(#{ui := U, pane := P}, F, A) -> cui(U, F, [P | A]).

loop(S = #{ui := {M, _}, pane := Pane}) ->
    receive
	{file, File} ->
	    loop(results(stop(S#{file := File}), []));
	toggle ->
	    loop(show(S, not maps:get(shown, S)));
	{csp_solve_done, W, Results} when W =:= map_get(worker, S) ->
	    pui(S, busy, [false]),
	    loop(results(S#{worker := none}, Results));
	{csp_solve_line, W, Results} when W =:= map_get(worker, S) ->
	    loop(results(S, Results));
	Msg ->
	    case M:event(Pane, Msg) of
		close -> loop(show(S, false));
		{prove, Text, K} -> loop(prove(S, Text, K));
		{pick, I} -> loop(pick(S, I));
		none -> loop(S)
	    end
    end.

%% Shown and hidden; hidden, the panel lets go of the trace it shows. The
%% panel lights the bar's button.
show(S = #{panel := Panel}, On) ->
    pui(S, show, [On]),
    Panel ! {candid_pane, "solver", On},
    On orelse (Panel ! {csp_solve, closed}),
    S#{shown := On}.

prove(S = #{file := none}, _Text, _K) ->
    results(S, [{0, "", "", "bad", "no program to prove", none}]);
prove(S0, Text, K) ->
    S = stop(S0),
    Self = self(),
    File = maps:get(file, S),
    W = spawn_link(fun() ->
			   Rs = run(File, parse(Text), K,
				    fun(Rs) -> Self ! {csp_solve_line, self(), Rs} end),
			   Self ! {csp_solve_done, self(), Rs}
		   end),
    pui(S, busy, [true]),
    results(S#{worker := W}, []).

%% A run still going is not wanted any more.
stop(S = #{worker := none}) -> S;
stop(S = #{worker := W}) ->
    unlink(W),
    exit(W, kill),
    pui(S, busy, [false]),
    S#{worker := none}.

results(S, Rs0) ->
    Rs = [{I, Kind, Text, Cls, lists:flatten(Answer), T}
	  || {I, Kind, Text, Cls, Answer, T} <- Rs0],
    pui(S, results, [[{I, Kind, Text, Cls, Answer, T =/= none}
		      || {I, Kind, Text, Cls, Answer, T} <- Rs]]),
    S#{results := Rs}.

pick(S = #{panel := Panel, results := Rs}, I) ->
    case lists:keyfind(I, 1, Rs) of
	{I, _Kind, Text, _Cls, Answer, T} when T =/= none ->
	    Panel ! {csp_solve, trace, Answer ++ ": " ++ Text, T};
	_ -> ok
    end,
    S.

%%% ------------------------------------------------------------ the lines

%% [{LineNo, Kind, Text}], or {LineNo, error, Why} for a line not understood.
parse(Text) ->
    Ls = string:split(Text, "\n", all),
    [L || {N, Line} <- lists:zip(lists:seq(1, length(Ls)), Ls),
	  L <- line(N, uncomment(Line))].

uncomment(Line) ->
    string:trim(hd(string:split(Line, "//"))).

line(_N, "") -> [];
line(N, Line) ->
    {Kind, Rest} = case string:split(Line, " ") of
		       [K, R] -> {K, string:trim(R)};
		       [K] -> {K, ""}
		   end,
    case {lists:member(Kind, ["assume", "invariant", "reach"]), Rest} of
	{true, ""} -> [{N, error, Kind ++ " what?"}];
	{true, _} -> [{N, Kind, Rest}];
	{false, _} -> [{N, error, "not assume, invariant or reach: " ++ Kind}]
    end.

%% Each line's answer, in order: {LineNo, Kind, Text, Cls, Answer, Trace},
%% Cls ok | bad | "" and Trace none or {At, Rows, Model}.
run(File, Lines, K) -> run(File, Lines, K, fun(_) -> ok end).

run(File, Lines, K, Said) ->
    {Rs, _} = lists:foldl(
		fun(L, {Acc, As}) ->
			{{N, Ki, T, C, A, Tr}, As1} = one(File, L, K, As),
			R = {N, Ki, T, C, lists:flatten(A), Tr},
			Acc1 = Acc ++ [R],
			Said(Acc1),
			{Acc1, As1}
		end, {[], []}, Lines),
    Rs.

one(_File, {N, error, Why}, _K, As) ->
    {{N, "", "", "bad", Why, none}, As};
%% Taken as it is, and checked to translate.
one(File, {N, "assume", T}, _K, As) ->
    case model(File, "1 == 1", As ++ [T]) of
	{ok, _} -> {{N, "assume", T, "", "assumed", none}, As ++ [T]};
	E -> {{N, "assume", T, "bad", why(E), none}, As}
    end;
%% Every cycle: !(T) is never reached. Proved, it holds for what follows.
one(File, {N, "invariant", T}, K, As) ->
    case solve(File, "!(" ++ T ++ ")", K, As) of
	{proved, I} ->
	    {{N, "invariant", T, "ok",
	      io_lib:format("holds (~w-induction)", [I]), none}, As ++ [T]};
	{found, At, Rows, M} ->
	    {{N, "invariant", T, "bad",
	      io_lib:format("broken in cycle ~w", [At]), {At, Rows, M}}, As};
	{none, _} ->
	    {{N, "invariant", T, "",
	      io_lib:format("not broken within ~w cycles, not proved", [K]),
	      none}, As};
	E -> {{N, "invariant", T, "bad", why(E), none}, As}
    end;
one(File, {N, "reach", T}, K, As) ->
    R = case solve(File, T, K, As) of
	    {found, At, Rows, M} ->
		{"ok", io_lib:format("reached in cycle ~w", [At]), {At, Rows, M}};
	    {proved, I} ->
		{"bad", io_lib:format("never (~w-induction)", [I]), none};
	    {none, _} ->
		{"", io_lib:format("not within ~w cycles, not proved never", [K]),
		 none};
	    E -> {"bad", why(E), none}
	end,
    {Cls, Answer, Tr} = R,
    {{N, "reach", T, Cls, lists:flatten(Answer), Tr}, As}.

model(File, Goal, As) ->
    try candyspeak_varp:model(File, [{reach, Goal}, {params, fixed},
				     {cycle_assumes, As}])
    catch throw:Why -> {error, Why}
    end.

solve(File, Goal, K, As) ->
    case {model(File, Goal, As), candyspeak_varp:varp_cmd()} of
	{_, none} -> {error, varp};
	{{ok, M = #{name := Name}}, Sh} ->
	    case candyspeak_varp:prove(M, "--property " ++ Name ++ "_reach",
				       K, ?TIMEOUT, Sh) of
		{found, At, Rows} -> {found, At, Rows, M};
		Other -> Other
	    end;
	{E, _} -> E
    end.

why({error, varp}) ->
    "varp not found: put varp on the code path, or set VARP_SH";
why(no_transitions) ->
    "the model has NO transitions: every goal would come back unreachable, "
	"and any proof would say nothing -- see the log";
why({error, {instances_not_modelled, Ms}}) ->
    "no #module for " ++ string:join(Ms, ", ");
why({error, {varp_annotate, _Loc, _Kind, {not_modelled, _T, Names}}}) ->
    "the model has nothing for " ++ string:join(Names, ", ");
why({error, {varp_annotate, _Loc, _Kind, {syntax, S}}}) ->
    "syntax: " ++ S;
why({error, {varp_annotate, _Loc, _Kind, Why}}) ->
    lists:flatten(io_lib:format("~p", [Why]));
why({error, Out}) when is_list(Out) ->
    "varp: " ++ hd(string:split(Out, "\n") ++ [""]);
why(Error) ->
    lists:flatten(io_lib:format("~p", [Error])).

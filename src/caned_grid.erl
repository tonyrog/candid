%%% A rung on a grid of characters: caned's ladder in a terminal.
%%%
%%%   ├──┬─┤ x + 1 < y ├──┤ x > 15 ├─┬──( R1 )─┤
%%%   │  └─┤ z == 17 ├───────────────┘         │
%%%
%%% An AND runs across, wired on one row (the RAIL); an OR stacks its
%%% branches between two connectors, its rail its first branch's. A contact is
%%% `┤ text ├', a hole `┤ ░ ├'. The same shape csp_ladder draws in pixels.
%%%
%%% An ELEMENT is {W, H, Rail, Cells}, Cells [{X, Y, Char, Attr}] from 0,0.
%%% Attr says what a cell is -- wire, contact, hole, coil, text -- or `cur'
%%% for the contact the cursor is on. Every contact's cells carry its path
%%% too ({Attr, Path}), so a click or a selection finds it.

-module(caned_grid).

-export([el/2, el/3, rung/6, rows/1, text_el/2]).

%% The element of tree T, Cur the cursor's path (none: no cursor here), Sel
%% a range of caned_tree's that is selected (none).
el(T, Cur) -> el(T, Cur, none).

el(T, Cur, Sel) -> el_(T, [], Cur, Sel).

%% No condition: a wire, the cursor's or a selected one marked.
el_({leaf, always}, P, Cur, Sel) ->
    A = case {P =:= Cur, Sel =/= none andalso caned_tree:in_range(P, Sel)} of
	    {_, true} -> always_sel;
	    {true, _} -> always_cur;
	    _ -> always
	end,
    {4, 1, 0, [{I, 0, $─, {A, P}} || I <- lists:seq(0, 3)]};
el_({leaf, X}, P, Cur, Sel) ->
    Txt = case X of
	      {hole, _} -> "░";
	      _ -> holes(candyspeak_eval:text(X))
	  end,
    A = case {P =:= Cur, Sel =/= none andalso caned_tree:in_range(P, Sel), X} of
	    {_, true, _} -> sel;
	    {true, false, _} -> cur;
	    {false, false, {hole, _}} -> hole;
	    {false, false, _} -> contact
	end,
    S = "┤ " ++ Txt ++ " ├",
    {length(S), 1, 0, [{I, 0, C, {A, P}} || {I, C} <- enum(S)]};
el_({'not', T}, P, Cur, Sel) ->
    {W, H, R, Cs} = el_(T, P ++ [1], Cur, Sel),
    {W + 1, H, R, [{0, R, $¬, wire} | shift(Cs, 1, 0)]};
el_({'and', Ks}, P, Cur, Sel) ->
    Es = [el_(K, P ++ [I], Cur, Sel) || {I, K} <- enum1(Ks)],
    across(Es);
el_({'or', Ks}, P, Cur, Sel) ->
    Es = [el_(K, P ++ [I], Cur, Sel) || {I, K} <- enum1(Ks)],
    stack(Es).

%% A hole inside a contact's text is drawn as one: the `_' no name is part of.
holes(T) -> holes([$\s | T], []).

holes([P, $_ | R], Acc) ->
    case name_char(P) orelse (R =/= [] andalso name_char(hd(R))) of
	true  -> holes([$_ | R], [P | Acc]);
	false -> holes([$░ | R], [P | Acc])
    end;
holes([P | R], Acc) -> holes(R, [P | Acc]);
holes([], Acc) -> tl(lists:reverse(Acc)).

name_char(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
		    orelse (C >= $0 andalso C =< $9) orelse C =:= $_.

%% Side by side, joined by a wire on the rail they share.
across(Es) ->
    R = lists:max([Er || {_, _, Er, _} <- Es]),
    {Cs, X} = lists:foldl(
		fun({W, _H, Er, ECs}, {Acc, X0}) ->
			Wire = case X0 of
				   0 -> [];
				   _ -> [{X0, R, $─, wire}, {X0 + 1, R, $─, wire}]
			       end,
			Xe = case X0 of 0 -> 0; _ -> X0 + 2 end,
			{Acc ++ Wire ++ shift(ECs, Xe, R - Er), Xe + W}
		end, {[], 0}, Es),
    H = lists:max([Eh + R - Er || {_, Eh, Er, _} <- Es]),
    {X, H, R, Cs}.

%% One under the other between two connectors; each branch wired out to the
%% widest.
stack(Es) ->
    Wm = lists:max([W || {W, _, _, _} <- Es]),
    W = Wm + 4,
    {Placed, H} = lists:mapfoldl(fun(E = {_, Eh, _, _}, Y) -> {{Y, E}, Y + Eh} end,
				 0, Es),
    Rails = [Y + Er || {Y, {_, _, Er, _}} <- Placed],
    N = length(Rails),
    Top = hd(Rails), Bot = lists:last(Rails),
    Branch = fun({I, {Y, {Ew, _, Er, ECs}}}) ->
		     Ry = Y + Er,
		     {L, Rc} = case I of
				   1 -> {$┬, $┬};
				   N -> {$└, $┘};
				   _ -> {$├, $┤}
			       end,
		     [{0, Ry, L, wire}, {1, Ry, $─, wire}, {W - 1, Ry, Rc, wire}] ++
			 [{X, Ry, $─, wire} || X <- lists:seq(2 + Ew, W - 2)] ++
			 shift(ECs, 2, Y)
	     end,
    Bars = [{X, Y, $│, wire} || X <- [0, W - 1], Y <- lists:seq(Top, Bot),
				not lists:member(Y, Rails)],
    {W, H, Top, lists:append([Branch(B) || B <- enum1(Placed)]) ++ Bars}.

%% The whole rung: the left rail, the condition, wire out to Width, the coil,
%% wire out to CoilW, the right rail. Width and CoilW are the widest on the
%% screen, so the coils and the right rail line up.
%% The coil's path is `coil': the cursor can be on it, a selection of the
%% whole rule (Sel `rule') has it.
rung(T, Coil, Cur, Sel, Width, CoilW) ->
    {W, H, R, Cs} = el(T, Cur, Sel),
    CoilA = if Sel =:= rule -> coil_sel;
	       Cur =:= coil -> coil_cur;
	       true -> coil
	    end,
    C0 = "( " ++ Coil ++ " )",
    C = C0 ++ lists:duplicate(max(0, CoilW + 4 - length(C0)), $─),
    Wc = length(C),
    X1 = 2 + Width + 2,                            % where the coil starts
    Cells = [{0, R, $├, wire}, {1, R, $─, wire}] ++ shift(Cs, 2, 0) ++
	[{X, R, $─, wire} || X <- lists:seq(2 + W, X1 - 1)] ++
	[{X1 + I, R, Ch, case Ch of $─ -> wire; _ -> {CoilA, coil} end}
	 || {I, Ch} <- enum(C)] ++
	[{X1 + Wc, R, $─, wire}, {X1 + Wc + 1, R, $┤, wire}] ++
	[{0, Y, $│, wire} || Y <- lists:seq(0, H - 1), Y =/= R] ++
	[{X1 + Wc + 1, Y, $│, wire} || Y <- lists:seq(0, H - 1), Y =/= R],
    {X1 + Wc + 2, H, R, Cells}.

%% A line that is no rung: its text, one row.
text_el(S, Attr) -> {length(S), 1, 0, [{I, 0, C, Attr} || {I, C} <- enum(S)]}.

%% The element as rows: each a list of {Attr, String} runs, blanks between.
rows({W, H, _R, Cells}) ->
    G = maps:from_list([{{X, Y}, {C, A}} || {X, Y, C, A} <- Cells]),
    [runs([maps:get({X, Y}, G, {$\s, blank}) || X <- lists:seq(0, W - 1)])
     || Y <- lists:seq(0, H - 1)].

runs([]) -> [];
runs([{C, A} | T]) ->
    {Same, Rest} = lists:splitwith(fun({_, A1}) -> A1 =:= A end, T),
    [{A, [C | [X || {X, _} <- Same]]} | runs(Rest)].

shift(Cs, Dx, Dy) -> [{X + Dx, Y + Dy, C, A} || {X, Y, C, A} <- Cs].

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).
enum1(L) -> lists:zip(lists:seq(1, length(L)), L).

%%% The code view's rungs as a picture: where every piece goes, and what it
%%% looks like under its classes -- for a renderer that draws, not one that
%%% builds a widget per contact. Both renderers draw the same list on a canvas
%%% of their own (csp_code_wx on a bitmap, csp_code_wse on a <canvas>); what
%%% differs is only how a rectangle, a line and a text are put down.
%%%
%%% The font is a fixed width one, so the layout needs two numbers from the
%%% renderer: the width of a character and the height of a line,
%%% #{cw, ch}. Everything is in pixels from there.
%%%
%%% A PIECE is a box (a contact, a coil), a wire, or a text, placed, with the
%%% id paint/4 names it by (csp_code_wse has the ids and the classes) and the
%%% row it is in, since a row whose block is not in force dims all of it.
%%%
%%% An OP is what a renderer draws, colours as {R, G, B} in the dark theme:
%%%
%%%   {rect, X, Y, W, H, Radius, Fill, Stroke, Dash}   Fill, Stroke: none | C
%%%   {line, X1, Y1, X2, Y2, C, Width, Dash}
%%%   {text, X, Y, Text, C, Bold}                      Y is the top
%%%
%%% Ladder: an AND runs across, an OR stacks its branches between two rails,
%%% the coil at the end of the rung. Code: the rule as a line of text, the
%%% contacts in it.

-module(csp_ladder).

-export([layout/3, size/1, set/2, ops/2, hit/3]).
-export([colour/1]).

-define(BG,    {18, 18, 18}).
-define(WIRE,  {102, 102, 102}).
-define(PADX,  6).                  % a contact's text from its frame
-define(PADY,  2).
-define(CPADX, 9).                  % a coil's
-define(WMIN,  10).                 % the shortest wire
-define(RAIL,  2).                  % an OR's rails
-define(GAP,   6).                  % between two rows
-define(MARK,  3).                  % a mark's frame outside the box

%%% ------------------------------------------------------------ the layout

%% The rules of a tab (csp_code:rules/1) drawn as ladder or code.
layout(Rules, Mode, M = #{cw := _, ch := _}) ->
    {Ps, Y, W} = lists:foldl(fun(R, Acc) -> row(R, Mode, M, Acc) end,
			     {[], ?GAP, 0}, gates(Rules)),
    Pieces = list_to_tuple(lists:reverse(Ps)),
    #{mode => Mode, pieces => Pieces, ids => ids(Pieces), w => W + ?GAP,
      h => Y + ?GAP, cls => #{}}.

size(#{w := W, h := H}) -> {W, H}.

%% The gate headers numbered as csp_code numbers them: g0, g1 ... in order.
gates(Rules) ->
    {Rs, _} = lists:mapfoldl(fun({gate, 'end', _} = G, I) -> {{G, none}, I};
				({gate, _, _} = G, I) -> {{G, I}, I + 1};
				(R, I) -> {{R, none}, I}
			     end, 0, Rules),
    Rs.

row({{gate, 'end', _}, _}, _Mode, M = #{ch := Ch}, {Ps, Y, W}) ->
    T = "#end",
    {[txt(none, none, 0, Y, T, {68, 85, 102}) | Ps], Y + Ch + 8, max(W, tw(M, T))};
row({{gate, Kind, Arg}, G}, _Mode, M = #{ch := Ch}, {Ps, Y0, W}) ->
    T = lists:flatten(case Kind of
			  in     -> ["#in ", lists:join(" ", Arg)];
			  'when' -> ["#when ", candyspeak_eval:text(Arg)]
		      end),
    Y = Y0 + 10,
    {[txt("g" ++ integer_to_list(G), none, 0, Y, T, gate) | Ps],
     Y + Ch + ?GAP, max(W, tw(M, T))};
row({R = #{no := N, line := Ln, guard := Gd, assigns := As}, _}, Mode, M,
    {Ps, Y, W}) ->
    K = "k" ++ integer_to_list(N),
    Label = lists:flatten(
	      case {Mode, R} of
		  {ladder, #{coil := Tgt}} -> candyspeak_eval:text(Tgt);
		  {code, #{coil := Tgt}}   -> [candyspeak_eval:text(Tgt), " ="];
		  _ -> lists:join(", ", [csp_code:assign(A) || A <- As])
	      end),
    {Rw, Rh, Rail, Rps} = rung(Mode, M, K, Label, Gd, R),
    %% The box that switches the rule on and off, then its number as csp
    %% numbers it -- what /list shows and #disable takes, not its line (Ln,
    %% where the rule is written, which the fired rules are matched by).
    _ = Ln,
    Ch = maps:get(ch, M),
    Cs = Ch - 4,
    Cb = {box, "x" ++ integer_to_list(N), none, 0, Rail - Cs div 2, Cs, Cs,
	  "", check, 0},
    Cbw = Cs + 6,
    Lnw = round(4 * maps:get(cw, M)) + 10,
    LnT = integer_to_list(N),
    Lp = txt(none, none, Cbw + Lnw - 10 - tw(M, LnT), Rail - Ch div 2,
	     LnT, {85, 85, 85}),
    RowId = "r" ++ integer_to_list(N),
    Placed = [setelement(3, P, RowId) || P <- [Cb, Lp | shift(Rps, Cbw + Lnw, 0)]],
    {lists:reverse(shift(Placed, 0, Y)) ++ Ps, Y + Rh + ?GAP,
     max(W, Cbw + Lnw + Rw)}.

%% {W, H, Rail, Pieces} of the rung right of its line number.
rung(ladder, M, K, Label, undefined, _R) ->
    across(M, [wire(40), coil(M, K, Label, ladder)]);
rung(ladder, M, K, Label, Gd, _R) ->
    {G, _} = ladder(M, K, Gd, 0),
    across(M, [wire(?WMIN), G, wire(?WMIN), coil(M, K, Label, ladder)]);
rung(code, M, K, Label, undefined, _R) ->
    across0([coil(M, K, Label, code)]);
rung(code, M, K, Label, Gd, R) ->
    Sep = case R of
	      #{coil := _} -> [text(M, " ", op)];
	      _            -> [text(M, " ? ", op)]
	  end,
    {G, _} = code(M, K, Gd, 0, 0),
    across0([coil(M, K, Label, code)] ++ Sep ++ G).

%% AND across: the wire between two contacts. Returns {Element, Next}.
ladder(M, K, X = {'&&', _, _, _}, I) ->
    {Es, I1} = lists:mapfoldl(fun(C, J) -> ladder(M, K, C, J) end, I,
			      csp_code:chain('&&', X)),
    {across(M, lists:join(wire(?WMIN), Es)), I1};
%% OR down: each branch wired to the right rail, the rails from the first
%% branch to the last.
ladder(M, K, X = {'||', _, _, _}, I) ->
    {Es, I1} = lists:mapfoldl(fun(C, J) -> ladder(M, K, C, J) end, I,
			      csp_code:chain('||', X)),
    W = lists:max([Ew || {Ew, _, _, _} <- Es]) + 2 * ?WMIN,
    {Bs, H} = lists:mapfoldl(
		fun({Ew, Eh, Er, Eps}, Y) ->
			Ps = shift(Eps, ?RAIL + ?WMIN, Y) ++
			    [wire_piece(?RAIL, Y + Er, ?RAIL + ?WMIN, Y + Er),
			     wire_piece(?RAIL + ?WMIN + Ew, Y + Er,
					W + ?RAIL, Y + Er)],
			{{Y + Er, Ps}, Y + Eh + 2}
		end, 0, Es),
    Top = element(1, hd(Bs)),
    Bot = element(1, lists:last(Bs)),
    Rails = [{wire, none, none, ?RAIL div 2, Top, ?RAIL div 2, Bot, ?RAIL},
	     {wire, none, none, W + ?RAIL + ?RAIL div 2, Top,
	      W + ?RAIL + ?RAIL div 2, Bot, ?RAIL}],
    {{W + 2 * ?RAIL, H - 2, (Top + Bot) div 2,
      Rails ++ lists:append([Ps || {_, Ps} <- Bs])}, I1};
ladder(M, K, X, I) ->
    {contact(M, K, I, X, ladder), I + 1}.

%% The same walk as text: the contacts in order, the operators between.
code(M, K, X = {Op, _, _, _}, I, P) when Op =:= '&&'; Op =:= '||' ->
    Q = case Op of '||' -> 1; '&&' -> 2 end,
    {Es, I1} = lists:mapfoldl(fun(C, J) -> code(M, K, C, J, Q + 1) end, I,
			      csp_code:chain(Op, X)),
    Sep = text(M, " " ++ atom_to_list(Op) ++ " ", op),
    In = lists:append(lists:join([Sep], Es)),
    {case Q < P of
	 true  -> [text(M, "(", op)] ++ In ++ [text(M, ")", op)];
	 false -> In
     end, I1};
code(M, K, X, I, _P) ->
    {[contact(M, K, I, X, code)], I + 1}.

%%% The elements, {W, H, Rail, Pieces}, the pieces placed from 0,0.

contact(M, K, I, X, Mode) ->
    Id = K ++ "_" ++ integer_to_list(I),
    box(M, Id, lists:flatten(candyspeak_eval:text(X)), contact, Mode).

coil(M, K, Label, Mode) -> box(M, K, Label, coil, Mode).

box(M = #{ch := Ch}, Id, Text, Kind, Mode) ->
    Px = case {Mode, Kind} of
	     {code, _}        -> 2;
	     {ladder, coil}   -> ?CPADX;
	     {ladder, contact} -> ?PADX
	 end,
    Py = case Mode of code -> 0; ladder -> ?PADY end,
    W = tw(M, Text) + 2 * Px + 2,
    H = Ch + 2 * Py + 2,
    {W, H, H div 2, [{box, Id, none, 0, 0, W, H, Text, Kind, Px}]}.

text(M = #{ch := Ch}, T, Style) ->
    {tw(M, T), Ch, Ch div 2, [txt(none, none, 0, 0, T, Style)]}.

wire(N) -> {wire, N}.

wire_piece(X1, Y1, X2, Y2) -> {wire, none, none, X1, Y1, X2, Y2, 2}.

%% Elements in a row, their rails on one line; a {wire, N} fills N across.
across(_M, Es) -> across0(Es).

across0(Es) ->
    Rail = lists:max([0 | [R || {_, _, R, _} <- Es]]),
    {X, H, Ps} =
	lists:foldl(
	  fun({wire, N}, {X, H, Ps}) ->
		  {X + N, H, [wire_piece(X, Rail, X + N, Rail) | Ps]};
	     ({W, Eh, R, Eps}, {X, H, Ps}) ->
		  Dy = Rail - R,
		  {X + W, max(H, Dy + Eh), lists:reverse(shift(Eps, X, Dy)) ++ Ps}
	  end, {0, 0, []}, Es),
    {X, max(H, 2 * Rail), Rail, lists:reverse(Ps)}.

txt(Id, Row, X, Y, T, Style) -> {txt, Id, Row, X, Y, T, Style}.

tw(#{cw := Cw}, T) -> round(Cw * length(T)).

shift(Ps, Dx, Dy) -> [shift1(P, Dx, Dy) || P <- Ps].

shift1({box, Id, R, X, Y, W, H, T, K, Px}, Dx, Dy) ->
    {box, Id, R, X + Dx, Y + Dy, W, H, T, K, Px};
shift1({wire, Id, R, X1, Y1, X2, Y2, Lw}, Dx, Dy) ->
    {wire, Id, R, X1 + Dx, Y1 + Dy, X2 + Dx, Y2 + Dy, Lw};
shift1({txt, Id, R, X, Y, T, S}, Dx, Dy) ->
    {txt, Id, R, X + Dx, Y + Dy, T, S}.

%%% ------------------------------------------------------------- painting

%% The classes paint/4 sent, [Id, Class ...]: those of this picture are kept,
%% the rest given back for the renderer's other pieces. {L, Rest, Changed},
%% Changed true when the picture has to be drawn again.
set(L = #{cls := Cls, ids := Ids}, Cs) ->
    {Mine, Rest} = split(Cs, Ids, [], []),
    Cls1 = maps:merge(Cls, maps:from_list(
			     [{Id, string:lexemes(C, " ")} || {Id, C} <- Mine])),
    {L#{cls := Cls1}, Rest, Cls1 =/= Cls}.

split([Id, C | T], Ids, Mine, Rest) ->
    case maps:is_key(Id, Ids) of
	true  -> split(T, Ids, [{Id, C} | Mine], Rest);
	false -> split(T, Ids, Mine, [C, Id | Rest])
    end;
split([], _Ids, Mine, Rest) -> {lists:reverse(Mine), lists:reverse(Rest)}.

%% The ids drawn here: the boxes, the gate headers and the rows.
ids(Ps) ->
    maps:from_list(lists:append(
		     [[{Id, true} || Id <- [element(2, P), element(3, P)],
				     Id =/= none]
		      || P <- tuple_to_list(Ps)])).

%% What a click at X, Y means: a contact is marked by it, a rule's box
%% switches it off or on. The box gets a few pixels round it: it is small.
hit(#{pieces := Ps}, X, Y) ->
    In = fun(Bx, By, W, H, D) ->
		 X >= Bx - D andalso X < Bx + W + D andalso
		     Y >= By - D andalso Y < By + H + D
	 end,
    case [Id || {box, Id, _, Bx, By, W, H, _, check, _} <- tuple_to_list(Ps),
		In(Bx, By, W, H, 3)] of
	["x" ++ No | _] -> "dis=" ++ No;
	[] ->
	    case [Id || {box, Id, _, Bx, By, W, H, _, contact, _}
			    <- tuple_to_list(Ps), In(Bx, By, W, H, 0)] of
		[Id | _] -> "ct=" ++ Id;
		[]       -> none
	    end
    end.

%% The whole picture, Colours being csp_code's (the css colours by name).
ops(L = #{pieces := Ps}, Colours) ->
    lists:append([ops(L, P, Colours) || P <- tuple_to_list(Ps)]).

ops(L = #{cls := Cls}, P, Colours) ->
    Row = case element(3, P) of
	      none -> [];
	      R    -> maps:get(R, Cls, [])
	  end,
    %% not in force, or switched off (#disable)
    Off = lists:member("off", Row) orelse lists:member("dis", Row),
    Own = case element(2, P) of
	      none -> [];
	      Id   -> maps:get(Id, Cls, [])
	  end,
    Dim = Off andalso not is_check(P),
    [dim(Op, Dim) || Op <- piece(P, Own, maps:get(mode, L), Colours)].

piece({wire, _, _, X1, Y1, X2, Y2, Lw}, _Cls, _Mode, _C) ->
    [{line, X1, Y1, X2, Y2, ?WIRE, Lw, false}];
piece({txt, _, _, X, Y, T, gate}, Cls, _Mode, C) ->
    case lists:member("t", Cls) of
	true  -> [{text, X, Y, T, c(block, C), true}];
	false -> [{text, X, Y, T, {102, 136, 170}, false}]
    end;
piece({txt, _, _, X, Y, T, op}, _Cls, _Mode, _C) ->
    [{text, X, Y, T, {119, 119, 119}, false}];
piece({txt, _, _, X, Y, T, Col}, _Cls, _Mode, _C) ->
    [{text, X, Y, T, Col, false}];
piece({box, _, _, X, Y, W, H, T, contact, Px}, Cls, Mode, C) ->
    Has = fun(K) -> lists:member(K, Cls) end,
    {Fill, Stroke, Dash, Ink} =
	case {Mode, Has("t"), Has("u")} of
	    {ladder, true, _} -> {fill(true, C), c(true, C), false, ink(true, C)};
	    {ladder, _, true} -> {{30, 30, 30}, {85, 85, 85}, true, {102, 102, 102}};
	    {ladder, _, _}    -> {{30, 30, 30}, {85, 85, 85}, false, {153, 153, 153}};
	    {code, true, _}   -> {none, none, false, c(true, C)};
	    {code, _, true}   -> {none, none, false, {102, 102, 102}};
	    {code, _, _}      -> {none, none, false, {187, 187, 187}}
	end,
    Under = case {Mode, Has("u")} of
		{code, true} -> [{line, X + Px, Y + H - 2, X + W - Px, Y + H - 2,
				  {102, 102, 102}, 1, true}];
		_ -> []
	    end,
    Mark = case {Has("mt"), Has("mf")} of
	       {true, _} -> [mark(X, Y, W, H, c(want, C), false)];
	       {_, true} -> [mark(X, Y, W, H, c(unwant, C), true)];
	       _ -> []
	   end,
    [{rect, X, Y, W, H, 3, Fill, Stroke, Dash},
     {text, X + Px + 1, Y + (H - ch_of(H, Mode)) div 2, T, Ink, false}]
	++ Under ++ Mark;
%% A rule's switch: filled while the rule is on. Drawn undimmed, so the box
%% of a rule that is off still reads as a box to click.
piece({box, _, _, X, Y, W, H, _, check, _}, Cls, _Mode, _C) ->
    [{rect, X, Y, W, H, 2, none, {136, 136, 136}, false}] ++
	case lists:member("xon", Cls) of
	    true  -> [{rect, X + 3, Y + 3, W - 6, H - 6, 1, {170, 170, 170},
		       none, false}];
	    false -> []
	end;
piece({box, _, _, X, Y, W, H, T, coil, Px}, Cls, Mode, C) ->
    {Fill, Stroke, Ink} =
	case {Mode, lists:member("on", Cls), lists:member("nx", Cls)} of
	    {ladder, true, _} -> {fill(fired, C), c(fired, C), ink(fired, C)};
	    {ladder, _, true} -> {none, c(next, C), ink(next, C)};
	    {ladder, _, _}    -> {none, {85, 85, 85}, {153, 153, 153}};
	    {code, true, _}   -> {fill(fired, C), none, ink(fired, C)};
	    {code, _, true}   -> {none, none, c(next, C)};
	    {code, _, _}      -> {none, none, {187, 187, 187}}
	end,
    R = case Mode of ladder -> H div 2; code -> 2 end,
    [{rect, X, Y, W, H, R, Fill, Stroke, false},
     {text, X + Px + 1, Y + (H - ch_of(H, Mode)) div 2, T, Ink, false}].

is_check({box, _, _, _, _, _, _, _, check, _}) -> true;
is_check(_) -> false.

mark(X, Y, W, H, Col, Dash) ->
    {rect, X - ?MARK, Y - ?MARK, W + 2 * ?MARK, H + 2 * ?MARK, 4, none, Col, Dash}.

%% The text's height inside a box: the box less its padding and frame.
ch_of(H, ladder) -> H - 2 * ?PADY - 2;
ch_of(H, code)   -> H - 2.

%% A row whose block is not in force, a third of itself over the page.
dim(Op, false) -> Op;
dim({rect, X, Y, W, H, R, F, S, D}, true) ->
    {rect, X, Y, W, H, R, fade(F), fade(S), D};
dim({line, X1, Y1, X2, Y2, C, W, D}, true) -> {line, X1, Y1, X2, Y2, fade(C), W, D};
dim({text, X, Y, T, C, B}, true) -> {text, X, Y, T, fade(C), B}.

fade(none) -> none;
fade(C)    -> mix(C, 35, ?BG).

c(K, C) -> colour(maps:get(K, C)).
fill(K, C) -> mix(c(K, C), 25, {17, 17, 17}).
ink(K, C)  -> mix(c(K, C), 35, {255, 255, 255}).

mix({R1, G1, B1}, P, {R2, G2, B2}) ->
    F = fun(A, B) -> round((A * P + B * (100 - P)) / 100) end,
    {F(R1, R2), F(G1, G2), F(B1, B2)}.

%% A css colour as the panel writes them -- #rgb, #rrggbb -- as {R, G, B}.
colour({_, _, _} = C) -> C;
colour("#" ++ [R, G, B]) -> {hex([R, R]), hex([G, G]), hex([B, B])};
colour("#" ++ [R1, R2, G1, G2, B1, B2]) ->
    {hex([R1, R2]), hex([G1, G2]), hex([B1, B2])}.

hex(S) -> list_to_integer(S, 16).

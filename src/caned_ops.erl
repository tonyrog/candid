%%% caned's screen (caned_ui:screen/3, rows of {Attr, String} runs) in
%%% pixels: the ops csp_ladder hands a renderer --
%%%
%%%   {rect, X, Y, W, H, Radius, Fill, Stroke, Dash}   Fill, Stroke: none | C
%%%   {line, X1, Y1, X2, Y2, C, Width, Dash}
%%%   {text, X, Y, Text, C, Bold}                      Y is the top
%%%
%%% -- so candid's code view can draw caned's when the two are one. The grid
%%% is a fixed-width font's: #{cw, ch} the size of a character. A box-drawing
%%% character is drawn as the wires it stands for, a contact `┤ x ├' as a box
%%% with a wire in at each end, a coil `( R1 )' as a round one.
%%%
%%% The HITS go with the ops: {X, Y, W, H, Ln, Path} for every contact and
%%% coil, what a click or a rectangle finds, and for each rung's number, its
%%% handle (Path `handle').

-module(caned_ops).

-export([ops/2, hits_in/2, hit/3, handle_at/2, colour/1, node_rows/2]).

-define(BG, {18, 18, 18}).

%% {Ops, Hits}. The character's size may be fractional (a renderer measures
%% it, as candid's code view does): what is drawn is rounded to the pixel,
%% so a long line of text still falls where its cells are.
ops(Rows, M = #{ch := Ch}) ->
    {Ops, Hits, _} =
	lists:foldl(fun(Row, {O, H, Y}) ->
			    {O1, H1} = row(Row, Y, M),
			    {[O1 | O], [H1 | H], Y + Ch}
		    end, {[], [], 0}, Rows),
    {[{rect, -1, -1, 100000, 100000, 0, ?BG, none, false} |
      [px(Op) || Op <- lists:append(lists:reverse(Ops)) ++ focus(Rows, M)]],
     [{round(X), round(Y), round(W), round(H), L, P}
      || {X, Y, W, H, L, P} <- lists:append(lists:reverse(Hits))]}.

%% The cursor's node: a bar at its left edge, every row of it -- bright
%% while the keys come here, grey when they go elsewhere.
focus(Rows, #{ch := Ch}) ->
    case node_rows(Rows, Ch) of
        none -> [];
        {Y0, Y1, F} ->
            [{rect, 0, Y0, 4, Y1 - Y0, 0,
              case F of cur -> stroke(cur); idle -> {110, 110, 110} end, none, false}]
    end.

%% The rows the cursor's node is on, in pixels: {Y0, Y1, cur | idle} | none.
node_rows(Rows, Ch) ->
    Ys = [{I * Ch, F} || {I, [{{shade, _, F, _}, _} | _]} <- lists:enumerate(0, Rows),
                         F =/= none],
    case Ys of
        [] -> none;
        [{Y0, F} | _] -> {Y0, element(1, lists:last(Ys)) + Ch, F}
    end.

lighter({R, G, B}) -> {R + 10, G + 10, B + 10}.

lift({R, G, B}, K) -> {R + 6 * K, G + 6 * K, B + 6 * K}.

width(M) -> maps:get(w, M, 4000).

px({rect, X, Y, W, H, R, F, S, D}) -> {rect, round(X), round(Y), round(W), round(H), round(R), F, S, D};
px({line, X1, Y1, X2, Y2, C, W, D}) -> {line, round(X1), round(Y1), round(X2), round(Y2), C, W, D};
px({text, X, Y, T, C, B}) -> {text, round(X), round(Y), T, C, B}.

row(Runs, Y, M = #{cw := Cw}) ->
    {Os, Hs, _} =
	lists:foldl(fun({A, T}, {O, H, X}) ->
			    {O1, H1} = run(base(A), A, T, X, Y, M),
			    {[O1 | O], [H1 | H], X + Cw * length(T)}
		    end, {[], [], 0}, Runs),
    {lists:append(lists:reverse(Os)), lists:append(lists:reverse(Hs))}.

base({A, _}) -> A;
base(A) -> A.

%% A contact, the cursor's, a selected one, a hole: a box, a wire in and out.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch})
  when K =:= contact; K =:= cur; K =:= sel; K =:= hole; K =:= off;
       K =:= contact_t; K =:= contact_u ->
    W = Cw * length(T),
    Mid = Y + Ch / 2,
    Bx = X + Cw / 2, Bw = W - Cw,
    Inner = string:trim(lists:sublist(T, 2, length(T) - 2)),
    Ops = [{line, X, Mid, Bx, Mid, colour(wire), 1, false},
	   {line, Bx + Bw, Mid, X + W, Mid, colour(wire), 1, false},
	   {rect, Bx, Y + 2, Bw, Ch - 4, 3, fill(K), stroke(K),
	    K =:= hole orelse K =:= contact_u}] ++
	[{text, X + Cw * 2, Y, Inner, colour(K), K =:= cur} || K =/= hole],
    {Ops, hit(A, X, Y, W, Ch)};
%% A coil: round, its name inside; the cursor's or a selected one filled.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch})
  when K =:= coil; K =:= coil_cur; K =:= coil_sel; K =:= coil_off;
       K =:= coil_on; K =:= coil_nx ->
    W = Cw * length(T),
    Inner = string:trim(lists:sublist(T, 2, length(T) - 2)),
    {Fill, Stroke, Ink} = case K of
			      coil -> {none, colour(coil), colour(coil)};
                              coil_off -> {none, stroke(off), colour(off)};
                              coil_on -> {fill(fired), stroke(fired), colour(fired)};
                              coil_nx -> {none, stroke(fired), colour(coil)};
			      coil_cur -> {fill(cur), stroke(cur), colour(cur)};
			      coil_sel -> {fill(sel), stroke(sel), colour(sel)}
			  end,
    {[{rect, X + Cw / 2, Y + 2, W - Cw, Ch - 4, (Ch - 4) / 2, Fill, Stroke, false},
      {text, X + Cw * 2, Y, Inner, Ink, K =:= coil_cur}], hit(A, X, Y, W, Ch)};
%% No condition: a wire, a dashed box round it under the cursor.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch}) when K =:= always; K =:= always_cur; K =:= always_sel ->
    W = Cw * length(T),
    Mid = Y + Ch / 2,
    Box = case K of
	      always -> [];
	      always_cur -> [{rect, X + 1, Y + 3, W - 2, Ch - 6, 3, none, stroke(cur), true}];
	      always_sel -> [{rect, X + 1, Y + 3, W - 2, Ch - 6, 3, fill(sel), stroke(sel), true}]
	  end,
    {Box ++ [{line, X, Mid, X + W, Mid, colour(wire), 1, false}], hit(A, X, Y, W, Ch)};
%% A comment's frame: each double box-drawing character as its two lines.
run(K, A, T, X, Y, M = #{cw := Cw}) when K =:= frame; K =:= frame_cur; K =:= frame_edit ->
    {frames(T, X, Y, colour(K), M), hit(A, X, Y, Cw * length(T), maps:get(ch, M))};
%% Wires: each box-drawing character the lines it stands for.
%% The shade a row lies on, by what the line is: the whole width. Over it
%% its block's BANDS, one a level, each from where that level's lines start
%% (after the rule numbers, two characters a level), a shade lighter than
%% the one outside it: what is in a block lies on one ground. A faint line
%% over a block's head and its #else, under its #end -- what is left of the
%% bands on paper.
run({shade, Kind, F, {B, Role}}, _A, _T, _X, Y, M = #{cw := Cw, ch := Ch}) ->
    Base = case {shade(Kind), F} of
               {none, none} -> ?BG;
               {none, _} -> {28, 28, 28};
               {C, none} -> C;
               {C, _} -> lighter(C)
           end,
    X = fun(K) -> Cw * (5 + 2 * (K - 1)) end,
    Ground = [{rect, 0, Y, width(M), Ch, 0, Base, none, false} || Base =/= ?BG] ++
        [{rect, X(K), Y, width(M) - X(K), Ch, 0, lift(Base, K), none, false}
         || K <- lists:seq(1, B)],
    Rule = case Role of
               open -> [{line, X(B), Y, width(M), Y, colour(level), 1, false}];
               'else' -> [{line, X(B), Y, width(M), Y, colour(level), 1, false}];
               close -> [{line, X(B), Y + Ch - 1, width(M), Y + Ch - 1, colour(level), 1, false}];
               body -> []
           end,
    {Ground ++ Rule, []};
%% A rung's number, its handle: and in its second cell the rule's switch, a
%% box filled while the rule is on (#disable empties it); a click on it
%% switches.
run(K, A = {_, {L, handle}}, T, X, Y, #{cw := Cw, ch := Ch})
  when K =:= lineno; K =:= lineno_off ->
    S = min(Cw, Ch - 10),
    Bx = X + Cw + (Cw - S) / 2, By = Y + (Ch - S) / 2,
    Box = [{rect, Bx, By, S, S, 2, none, {136, 136, 136}, false}] ++
        [{rect, Bx + 2, By + 2, S - 4, S - 4, 1, {170, 170, 170}, none, false} || K =:= lineno],
    {Box ++ [{text, X + 2 * Cw, Y, lists:nthtail(2, T), colour(K), false}],
     [{X + Cw, Y, Cw, Ch, L, check} | hit(A, X + 2 * Cw, Y, Cw * (length(T) - 2), Ch)]};
%% The comment under the cursor, a declaration's field: on a box.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch})
  when K =:= comment_cur; K =:= field; K =:= field_cur; K =:= field_edit ->
    W = Cw * length(T),
    Box = case K of
              field -> {rect, X - 2, Y + 2, W + 4, Ch - 4, 3, none, {70, 70, 70}, false};
              field_edit -> {rect, X - 2, Y + 2, W + 4, Ch - 4, 3, fill(cur), stroke(cur), false};
              _ -> {rect, X - 2, Y + 1, W + 4, Ch - 2, 3, fill(cur), none, false}
          end,
    {[Box, {text, X, Y, T, colour(K), K =:= field_edit}], hit(A, X, Y, W, Ch)};
%% A menu in the status line: the choice Tab put in on a box.
run(K, _A, T, X, Y, #{cw := Cw, ch := Ch}) when K =:= menu; K =:= menu_sel ->
    W = Cw * length(T),
    {[{rect, X, Y, W, Ch, 0, {51, 51, 51}, none, false}] ++
         [{rect, X + 1, Y + 2, W - 2, Ch - 4, 3, fill(sel), stroke(sel), false} || K =:= menu_sel] ++
         [{text, X, Y, T, colour(K), false}], []};
%% A run of ─ is one line, not a line a character.
run(wire, _A, T, X, Y, M = #{ch := Ch}) ->
    {wires(T, X, Y + Ch / 2, M), []};
run(status, _A, T, X, Y, #{cw := Cw, ch := Ch}) ->
    {[{rect, X, Y, Cw * length(T), Ch, 0, {51, 51, 51}, none, false},
      {text, X, Y, T, colour(status), false}], []};
run(blank, _A, _T, _X, _Y, _M) -> {[], []};
run(K, A, T, X, Y, #{cw := Cw, ch := Ch}) ->
    case string:trim(T) of
	"" -> {[], []};
	_ -> {[{text, X, Y, T, colour(K), K =:= edit}], hit(A, X, Y, Cw * length(T), Ch)}
    end.

hit({_, {Ln, P}}, X, Y, W, H) -> [{X, Y, W, H, Ln, P}];
hit(_, _, _, _, _) -> [].

wires([], _X, _My, _M) -> [];
wires(T = [$─ | _], X, My, M = #{cw := Cw}) ->
    {Run, Rest} = lists:splitwith(fun(C) -> C =:= $─ end, T),
    X1 = X + Cw * length(Run),
    [{line, X, My, X1, My, colour(wire), 1, false} | wires(Rest, X1, My, M)];
wires([$\s | T], X, My, M = #{cw := Cw}) -> wires(T, X + Cw, My, M);
wires([C | T], X, My, M = #{cw := Cw, ch := Ch}) ->
    wire(C, X, My - Ch / 2, M) ++ wires(T, X + Cw, My, M).

%% The ends of the wires through a cell: left, right, up, down.
wire(C, X, Y, #{cw := Cw, ch := Ch}) ->
    Mx = X + Cw / 2, My = Y + Ch / 2,
    Ends = #{l => {X, My}, r => {X + Cw, My}, u => {Mx, Y}, d => {Mx, Y + Ch}},
    case C of
	$¬ -> [{text, X, Y, "¬", colour(wire), false}];
	_ ->
	    [{line, Mx, My, Ex, Ey, colour(wire), 1, false}
	     || D <- dirs(C), {Ex, Ey} <- [maps:get(D, Ends)]]
    end.

%% A run of ═ as its two lines, the rest a character at a time.
frames([], _X, _Y, _Ink, _M) -> [];
frames(T = [$═ | _], X, Y, Ink, M = #{cw := Cw, ch := Ch}) ->
    {Run, Rest} = lists:splitwith(fun(C) -> C =:= $═ end, T),
    X1 = X + Cw * length(Run),
    My = Y + Ch / 2,
    [{line, X, My - 2, X1, My - 2, Ink, 1, false},
     {line, X, My + 2, X1, My + 2, Ink, 1, false} | frames(Rest, X1, Y, Ink, M)];
frames([C | T], X, Y, Ink, M = #{cw := Cw}) ->
    frame(C, X, Y, Ink, M) ++ frames(T, X + Cw, Y, Ink, M).

%% ═ ║ and the corners, two lines 2 px either side of the middle; at a
%% corner the outer line goes round the inner.
frame(C, X, Y, Ink, #{cw := Cw, ch := Ch}) ->
    Mx = X + Cw / 2, My = Y + Ch / 2,
    L = fun(X1, Y1, X2, Y2) -> {line, X1, Y1, X2, Y2, Ink, 1, false} end,
    case C of
        $═ -> [L(X, My - 2, X + Cw, My - 2), L(X, My + 2, X + Cw, My + 2)];
        $║ -> [L(Mx - 2, Y, Mx - 2, Y + Ch), L(Mx + 2, Y, Mx + 2, Y + Ch)];
        _ ->
            {H, V} = case C of
                         $╔ -> {r, d}; $╗ -> {l, d}; $╚ -> {r, u}; $╝ -> {l, u};
                         _ -> {none, none}
                     end,
            case H of
                none -> [];
                _ ->
                    Ex = case H of r -> X + Cw; l -> X end,
                    Ey = case V of d -> Y + Ch; u -> Y end,
                    Sx = case H of r -> -1; l -> 1 end,
                    Sy = case V of d -> -1; u -> 1 end,
                    lists:append([[L(Mx + O * Sx, My + O * Sy, Ex, My + O * Sy),
                                   L(Mx + O * Sx, My + O * Sy, Mx + O * Sx, Ey)] || O <- [2, -2]])
            end
    end.

dirs($─) -> [l, r];
dirs($│) -> [u, d];
dirs($├) -> [u, d, r];
dirs($┤) -> [u, d, l];
dirs($┬) -> [l, r, d];
dirs($└) -> [u, r];
dirs($┘) -> [u, l];
dirs(_) -> [].

shade(rung) -> {25, 23, 19};
shade(card) -> {19, 22, 29};
shade(comment) -> {18, 25, 19};
shade(inline) -> {27, 21, 30};
shade(_) -> none.

fill(cur) -> {58, 52, 20};
fill(contact_t) -> {28, 70, 28};
fill(fired) -> {80, 60, 15};
fill(sel) -> {24, 52, 92};
fill(_) -> none.

stroke(cur) -> {255, 204, 68};
stroke(sel) -> {68, 170, 255};
stroke(hole) -> {204, 170, 68};
stroke(off) -> {80, 80, 80};
stroke(contact_t) -> {51, 255, 51};
stroke(contact_u) -> {130, 130, 130};
stroke(fired) -> {255, 187, 51};
stroke(_) -> {150, 150, 150}.

colour(wire) -> {102, 102, 102};
colour(contact) -> {221, 221, 221};
colour(cur) -> {255, 230, 150};
colour(sel) -> {200, 225, 255};
colour(hole) -> {204, 170, 68};
colour(coil) -> {136, 200, 220};
colour(lineno) -> {90, 90, 90};
colour(level) -> {70, 70, 70};
colour(comment) -> {120, 165, 110};
colour(frame) -> {80, 120, 75};
colour(frame_cur) -> {255, 204, 68};
colour(frame_edit) -> {230, 240, 220};
colour(kw) -> {136, 200, 220};
colour(opener) -> {200, 200, 120};
colour(field) -> {221, 221, 221};
colour(field_cur) -> {255, 230, 150};
colour(field_edit) -> {255, 255, 255};
colour(add) -> {130, 130, 130};
colour(menu) -> {200, 200, 200};
colour(menu_sel) -> {255, 255, 255};
colour(comment_cur) -> {170, 220, 150};
colour(note) -> {200, 240, 180};
colour(lineno_off) -> {200, 90, 90};
colour(off) -> {95, 95, 95};
colour(contact_t) -> {170, 255, 170};
colour(contact_u) -> {170, 170, 170};
colour(fired) -> {255, 220, 150};
colour(text) -> {170, 170, 170};
colour(status) -> {221, 221, 221};
colour(help) -> {130, 130, 130};
colour(msg) -> {230, 190, 80};
colour(error) -> {240, 100, 100};
colour(edit) -> {255, 255, 255};
colour(_) -> {170, 170, 170}.

%% What a click at X, Y is on: {Ln, Path} | none. Off every box, the one
%% nearest across on that row -- a click anywhere along a rung or a card
%% takes its nearest contact or field; a handle, a switch and an opener
%% only where they are.
hit(Hits, X, Y) ->
    case [{L, P} || {Hx, Hy, W, H, L, P} <- Hits,
		    X >= Hx, X < Hx + W, Y >= Hy, Y < Hy + H] of
	[H | _] -> H;
	[] ->
	    case lists:sort([{if X < Hx -> Hx - X; true -> X - (Hx + W) end, L, P}
			     || {Hx, Hy, W, H, L, P} <- Hits, Y >= Hy, Y < Hy + H,
				P =/= handle, P =/= check, P =/= open]) of
		[{_, L, P} | _] -> {L, P};
		[] -> none
	    end
    end.

%% The rung a row at Y is in, by the handles: the last one starting above
%% it. Ln | none.
handle_at(Hits, Y) ->
    case [L || {_, Hy, _, _, L, handle} <- Hits, Hy =< Y] of
	[] -> none;
	Ls -> lists:last(Ls)
    end.

%% The contacts a rectangle touches, all on the rung of the first:
%% {Ln, [Path]} | none.
hits_in(Hits, {X0, Y0, X1, Y1}) ->
    {Xa, Xb} = {min(X0, X1), max(X0, X1)},
    {Ya, Yb} = {min(Y0, Y1), max(Y0, Y1)},
    case [{L, P} || {Hx, Hy, W, H, L, P} <- Hits, P =/= handle, P =/= check, P =/= open,
		    Hx < Xb, Hx + W > Xa, Hy < Yb, Hy + H > Ya] of
	[] -> none;
	[{L, _} | _] = Hs -> {L, [P || {L1, P} <- Hs, L1 =:= L]}
    end.


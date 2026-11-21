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

-export([ops/2, hits_in/2, hit/3, handle_at/2, colour/1]).

-define(BG, {18, 18, 18}).

%% {Ops, Hits}.
ops(Rows, M = #{ch := Ch}) ->
    {Ops, Hits, _} =
	lists:foldl(fun(Row, {O, H, Y}) ->
			    {O1, H1} = row(Row, Y, M),
			    {O ++ O1, H ++ H1, Y + Ch}
		    end, {[], [], 0}, Rows),
    {[{rect, -1, -1, 100000, 100000, 0, ?BG, none, false} | Ops], Hits}.

row(Runs, Y, M = #{cw := Cw}) ->
    {Os, Hs, _} =
	lists:foldl(fun({A, T}, {O, H, X}) ->
			    {O1, H1} = run(base(A), A, T, X, Y, M),
			    {O ++ O1, H ++ H1, X + Cw * length(T)}
		    end, {[], [], 0}, Runs),
    {Os, Hs}.

base({A, _}) -> A;
base(A) -> A.

%% A contact, the cursor's, a selected one, a hole: a box, a wire in and out.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch})
  when K =:= contact; K =:= cur; K =:= sel; K =:= hole; K =:= off ->
    W = Cw * length(T),
    Mid = Y + Ch div 2,
    Bx = X + Cw div 2, Bw = W - Cw,
    Inner = string:trim(lists:sublist(T, 2, length(T) - 2)),
    Ops = [{line, X, Mid, Bx, Mid, colour(wire), 1, false},
	   {line, Bx + Bw, Mid, X + W, Mid, colour(wire), 1, false},
	   {rect, Bx, Y + 2, Bw, Ch - 4, 3, fill(K), stroke(K), K =:= hole}] ++
	[{text, X + Cw * 2, Y, Inner, colour(K), K =:= cur} || K =/= hole],
    {Ops, hit(A, X, Y, W, Ch)};
%% A coil: round, its name inside; the cursor's or a selected one filled.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch})
  when K =:= coil; K =:= coil_cur; K =:= coil_sel; K =:= coil_off ->
    W = Cw * length(T),
    Inner = string:trim(lists:sublist(T, 2, length(T) - 2)),
    {Fill, Stroke, Ink} = case K of
			      coil -> {none, colour(coil), colour(coil)};
                              coil_off -> {none, stroke(off), colour(off)};
			      coil_cur -> {fill(cur), stroke(cur), colour(cur)};
			      coil_sel -> {fill(sel), stroke(sel), colour(sel)}
			  end,
    {[{rect, X + Cw div 2, Y + 2, W - Cw, Ch - 4, (Ch - 4) div 2, Fill, Stroke, false},
      {text, X + Cw * 2, Y, Inner, Ink, K =:= coil_cur}], hit(A, X, Y, W, Ch)};
%% No condition: a wire, a dashed box round it under the cursor.
run(K, A, T, X, Y, #{cw := Cw, ch := Ch}) when K =:= always; K =:= always_cur; K =:= always_sel ->
    W = Cw * length(T),
    Mid = Y + Ch div 2,
    Box = case K of
	      always -> [];
	      always_cur -> [{rect, X + 1, Y + 3, W - 2, Ch - 6, 3, none, stroke(cur), true}];
	      always_sel -> [{rect, X + 1, Y + 3, W - 2, Ch - 6, 3, fill(sel), stroke(sel), true}]
	  end,
    {Box ++ [{line, X, Mid, X + W, Mid, colour(wire), 1, false}], hit(A, X, Y, W, Ch)};
%% A comment's frame: each double box-drawing character as its two lines.
run(K, A, T, X, Y, M = #{cw := Cw}) when K =:= frame; K =:= frame_cur; K =:= frame_edit ->
    {lists:append([frame(C, X + I * Cw, Y, colour(K), M) || {I, C} <- enum(T)]),
     hit(A, X, Y, Cw * length(T), maps:get(ch, M))};
%% Wires: each box-drawing character the lines it stands for.
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
run(wire, _A, T, X, Y, M = #{cw := Cw}) ->
    {lists:append([wire(C, X + I * Cw, Y, M) || {I, C} <- enum(T)]), []};
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

%% The ends of the wires through a cell: left, right, up, down.
wire(C, X, Y, #{cw := Cw, ch := Ch}) ->
    Mx = X + Cw div 2, My = Y + Ch div 2,
    Ends = #{l => {X, My}, r => {X + Cw, My}, u => {Mx, Y}, d => {Mx, Y + Ch}},
    case C of
	$¬ -> [{text, X, Y, "¬", colour(wire), false}];
	_ ->
	    [{line, Mx, My, Ex, Ey, colour(wire), 1, false}
	     || D <- dirs(C), {Ex, Ey} <- [maps:get(D, Ends)]]
    end.

%% ═ ║ and the corners, two lines 2 px either side of the middle; at a
%% corner the outer line goes round the inner.
frame(C, X, Y, Ink, #{cw := Cw, ch := Ch}) ->
    Mx = X + Cw div 2, My = Y + Ch div 2,
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

fill(cur) -> {58, 52, 20};
fill(sel) -> {24, 52, 92};
fill(_) -> none.

stroke(cur) -> {255, 204, 68};
stroke(sel) -> {68, 170, 255};
stroke(hole) -> {204, 170, 68};
stroke(off) -> {80, 80, 80};
stroke(_) -> {150, 150, 150}.

colour(wire) -> {102, 102, 102};
colour(contact) -> {221, 221, 221};
colour(cur) -> {255, 230, 150};
colour(sel) -> {200, 225, 255};
colour(hole) -> {204, 170, 68};
colour(coil) -> {136, 200, 220};
colour(lineno) -> {90, 90, 90};
colour(comment) -> {120, 165, 110};
colour(frame) -> {80, 120, 75};
colour(frame_cur) -> {255, 204, 68};
colour(frame_edit) -> {230, 240, 220};
colour(kw) -> {136, 200, 220};
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
colour(text) -> {170, 170, 170};
colour(status) -> {221, 221, 221};
colour(help) -> {130, 130, 130};
colour(msg) -> {230, 190, 80};
colour(error) -> {240, 100, 100};
colour(edit) -> {255, 255, 255};
colour(_) -> {170, 170, 170}.

%% The contacts a click at X, Y is on: {Ln, Path} | none.
hit(Hits, X, Y) ->
    case [{L, P} || {Hx, Hy, W, H, L, P} <- Hits,
		    X >= Hx, X < Hx + W, Y >= Hy, Y < Hy + H] of
	[H | _] -> H;
	[] -> none
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
    case [{L, P} || {Hx, Hy, W, H, L, P} <- Hits, P =/= handle,
		    Hx < Xb, Hx + W > Xa, Hy < Yb, Hy + H > Ya] of
	[] -> none;
	[{L, _} | _] = Hs -> {L, [P || {L1, P} <- Hs, L1 =:= L]}
    end.

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).

%%% The code view's renderer for the desktop: csp_code decides what the view
%%% shows, this draws it and lights it.
%%%
%%% The rungs are csp_ladder's picture, drawn on one panel when wx paints it
%%% (the canvas below); a click goes back as `xy=X,Y'. The rest -- the tab
%%% buttons, an object's values, the model frame and the trace table -- are
%%% widgets, registered by the ids of csp_code_wse's contract
%%% (candid_wx:register/4), so paint/4 finds them by name as the browser does.

-module(csp_code_wx).

-include_lib("wx/include/wx.hrl").

-export([new/4, metrics/2, shown/3, rungs/6, draw/3, paint/4, goal/3,
	 answer/5]).

-define(BG, {18, 18, 18}).

%% The view, hidden, with its tab buttons; the model frame (goal, clear,
%% solve, k) in the top frame's status row, the answer and the program's own
%% values below. See csp_code_wse:new/4 for what is sent on its events.
new(H, Where, Tabs, #{colours := Colours, ks := Ks, k := K0}) ->
    #{code := Right, status := {Top, Row}, top := {Top, TopS}} = Where,
    Box = wxPanel:new(Right),
    BoxS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Box, BoxS),
    Bar = wxBoxSizer:new(?wxHORIZONTAL),
    Pid = self(),
    Btns = case Tabs of
	       [_] -> [];
	       _ ->
		   [begin
			Tab = "tab=" ++ integer_to_list(I),
			B = candid_wx:btn(H, Box, Name,
					  #{click => fun() -> Pid ! {candid_wx, {code, Tab}}
						     end}),
			wxSizer:add(Bar, B, []),
			B
		    end || {I, #{name := Name}} <- enum(Tabs)]
	   end,
    wxSizer:add(BoxS, Bar, [{flag, ?wxBOTTOM}, {border, 8}]),
    Body = wxPanel:new(Box),
    wxWindow:setSizer(Body, wxBoxSizer:new(?wxVERTICAL)),
    wxSizer:add(BoxS, Body, []),
    Canvas = canvas(H, Box),
    wxSizer:add(BoxS, Canvas, []),
    wxSizer:add(wxWindow:getSizer(Right), Box, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxWindow:hide(Box),
    %% The model frame.
    {GoalF, Goal} = candid_wx:frame_box(Top, "goal"),
    wxWindow:setFont(Goal, candid_wx:font(H)),
    wxWindow:setMinSize(Goal, {320, -1}),
    wxSizer:add(Row, GoalF, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
			     {border, 12}]),
    [begin
	 B = candid_wx:btn(H, Top, L,
			   #{click => fun() -> Pid ! {candid_wx, {code, L}} end}),
	 wxSizer:add(Row, B, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
			      {border, case L of "clear" -> 4; _ -> 0 end}])
     end || L <- ["clear", "solve"]],
    Sel = candid_wx:menu_btn(H, Top, ["k \x{2264} " ++ integer_to_list(K)
				      || K <- Ks],
			     length(lists:takewhile(fun(K) -> K =/= K0 end, Ks)),
			     fun(I) -> Pid ! {candid_wx, {code, "k=" ++
						 integer_to_list(lists:nth(I, Ks))}}
			     end),
    wxSizer:add(Row, Sel, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}]),
    %% The answer: its text, and what a found trace brings.
    Res = wxPanel:new(Top),
    ResS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Res, ResS),
    ResT = candid_wx:text(H, Res, "", {170, 170, 170}),
    wxSizer:add(ResS, ResT, []),
    Extra = wxPanel:new(Res),
    wxWindow:setSizer(Extra, wxBoxSizer:new(?wxVERTICAL)),
    wxSizer:add(ResS, Extra, [{flag, ?wxEXPAND}]),
    wxSizer:add(TopS, Res, [{flag, ?wxEXPAND bor ?wxALL}, {border, 4}]),
    #{vars := MainVars} = hd(Tabs),
    vals(H, Top, TopS, "m_", none, MainVars, perm),
    wxWindow:layout(Top),
    #{box => Box, body => Body, canvas => Canvas, right => Right, top => Top,
      tab_buttons => Btns, event => code, goal => Goal, goal_frame => GoalF,
      res => ResT, extra => Extra, colours => Colours}.

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).

%% The values with no widget of their own: a cell each, its name a signal to
%% mark by click, a #local in italics.
vals(_H, _Parent, _Sizer, _Pre, _Obj, [], _Scope) -> ok;
vals(H, Parent, Sizer, Pre, Obj, Vars, Scope) ->
    G = wxGridSizer:new(0, 6, 2, 2),
    [begin
	 Full = case Obj of none -> N; _ -> Obj ++ "." ++ N end,
	 Cell = wxBoxSizer:new(?wxHORIZONTAL),
	 {F, T} = candid_wx:frame_box(Parent, N),
	 wxWindow:setFont(T, candid_wx:font(H)),
	 candid_wx:fg(H, T, case K of local -> {136, 170, 187};
						   var -> {136, 136, 136} end),
	 candid_wx:click(T, {code, "sig=" ++ Full}, self()),
	 candid_wx:register(H, "sv_" ++ Full, {frame, F}, Scope),
	 V = candid_wx:text(H, Parent, "", {221, 221, 221}),
	 wxWindow:setMinSize(V, {70, -1}),
	 candid_wx:register(H, Pre ++ N, {text, V}, Scope),
	 wxSizer:add(Cell, F, [{proportion, 1}]),
	 wxSizer:add(Cell, V, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
			       {border, 6}]),
	 wxSizer:add(G, Cell, [{flag, ?wxEXPAND}])
     end || {K, N} <- Vars],
    wxSizer:add(Sizer, G, [{flag, ?wxALL}, {border, 4}]).

shown(_H, #{box := Box, right := Right}, Show) ->
    wxWindow:show(Box, [{show, Show}]),
    wxWindow:layout(Right),
    wxScrolledWindow:fitInside(Right).

%% Tab I: its buttons, an object's bindings and values, and the canvas the
%% rungs are drawn on, Size big. Frozen and in one batch, so the head is not
%% seen at 0,0 before the layout puts it in its place.
rungs(H, Hd = #{right := Right}, _Mode, I, Tab, Size) ->
    wxWindow:freeze(Right),
    try wx:batch(fun() ->
			 candid_wx:in_scope(H, rung,
					    fun() -> rungs1(H, Hd, I, Tab, Size) end)
		 end)
    after wxWindow:thaw(Right)
    end.

rungs1(H, #{body := Body, canvas := C, box := Box, right := Right,
	    tab_buttons := Btns}, I, Tab, Size) ->
    [candid_wx:btn_on(H, B, J =:= I) || {J, B} <- enum(Btns)],
    candid_wx:forget(H, rung),
    wxWindow:destroyChildren(Body),
    head(H, Body, wxWindow:getSizer(Body), Tab),
    candid_wx:register(H, code_ops, [], perm),
    wxWindow:setMinSize(C, Size),
    wxWindow:setSize(C, Size),
    wxWindow:layout(Body),
    wxWindow:layout(Box),
    wxWindow:layout(Right),
    wxScrolledWindow:fitInside(Right),
    ok.

%% An object's bindings and its values.
head(_H, _Body, _BS, #{binds := none}) -> ok;
head(H, Body, BS, Tab = #{binds := {M, Bs}, vars := Vars, prefix := P}) ->
    T = candid_wx:text(H, Body, flat(["#", M, " ", maps:get(name, Tab), " ",
				      lists:join("  ", [csp_code:bind(B) || B <- Bs])]),
		       {136, 170, 187}),
    wxSizer:add(BS, T, [{flag, ?wxBOTTOM}, {border, 8}]),
    vals(H, Body, BS, "v_", P, Vars, rung).

%%% ------------------------------------------------------------- the canvas
%%%
%%% The rungs are csp_ladder's ops, drawn when the panel is painted -- so a
%%% scroll or the theme draws them again as they are -- and kept in the id
%%% table for that. A click goes to csp_code as `xy=X,Y', which says what is
%%% there.

canvas(H, Parent) ->
    C = wxPanel:new(Parent, [{style, ?wxFULL_REPAINT_ON_RESIZE}]),
    wxWindow:setFont(C, candid_wx:font(H)),
    wxWindow:setBackgroundStyle(C, ?wxBG_STYLE_PAINT),
    Pid = self(),
    wxPanel:connect(C, paint, [{callback,
				fun(_E, _O) ->
					DC = wxBufferedPaintDC:new(C),
					paint_ops(H, DC, ops(H)),
					wxBufferedPaintDC:destroy(DC)
				end}]),
    wxPanel:connect(C, left_down, [{callback,
				    fun(#wx{event = #wxMouse{x = X, y = Y}}, O) ->
					    Pid ! {candid_wx, {code, xy(X, Y)}},
					    wxEvent:skip(O)
				    end}]),
    C.

xy(X, Y) -> "xy=" ++ integer_to_list(X) ++ "," ++ integer_to_list(Y).

ops(H) ->
    case candid_wx:lookup(H, code_ops) of
	{ok, Ops} -> Ops;
	error     -> []
    end.

%% The width of a character and the height of a line in the view's font.
metrics(_H, #{canvas := C}) ->
    {W, Ht, _, _} = wxWindow:getTextExtent(C, "MMMMMMMMMM"),
    #{cw => W / 10, ch => Ht}.

%% The whole picture again.
draw(H, #{canvas := C}, Ops) ->
    candid_wx:register(H, code_ops, Ops, perm),
    wxWindow:refresh(C, [{eraseBackground, false}]).

%% A pen and a brush per colour and style, made once a paint.
paint_ops(H, DC, Ops) ->
    {W, Ht} = wxDC:getSize(DC),
    Bg = wxBrush:new(candid_wx:tc(H, ?BG)),
    wxDC:setBackground(DC, Bg),
    wxDC:clear(DC),
    wxBrush:destroy(Bg),
    _ = {W, Ht},
    Font = candid_wx:font(H),
    Bold = wxFont:new(wxFont:getPointSize(Font), ?wxFONTFAMILY_TELETYPE,
		      ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    wxDC:setFont(DC, Font),
    Tools = lists:foldl(fun(Op, T) -> op(H, DC, Op, T, Font, Bold) end, #{}, Ops),
    [case K of
	 {pen, _, _, _} -> wxPen:destroy(X);
	 {brush, _}     -> wxBrush:destroy(X)
     end || {K, X} <- maps:to_list(Tools)],
    wxFont:destroy(Bold),
    ok.

op(H, DC, {rect, X, Y, W, Ht, R, F, S, D}, T0, _F, _B) ->
    {Br, T1} = brush(H, F, T0),
    {Pen, T2} = pen(H, S, 1, D, T1),
    wxDC:setBrush(DC, Br),
    wxDC:setPen(DC, Pen),
    wxDC:drawRoundedRectangle(DC, {X, Y, W, Ht}, R),
    T2;
op(H, DC, {line, X1, Y1, X2, Y2, C, W, D}, T0, _F, _B) ->
    {Pen, T1} = pen(H, C, W, D, T0),
    wxDC:setPen(DC, Pen),
    wxDC:drawLine(DC, {X1, Y1}, {X2, Y2}),
    T1;
op(H, DC, {text, X, Y, Txt, C, Bold}, T, Font, BoldF) ->
    Bold andalso wxDC:setFont(DC, BoldF),
    wxDC:setTextForeground(DC, candid_wx:tc(H, C, fg)),
    wxDC:drawText(DC, Txt, {X, Y}),
    Bold andalso wxDC:setFont(DC, Font),
    T.

brush(_H, none, T) -> {?wxTRANSPARENT_BRUSH, T};
brush(H, C, T) ->
    case maps:find({brush, C}, T) of
	{ok, B} -> {B, T};
	error   -> B = wxBrush:new(candid_wx:tc(H, C)), {B, T#{{brush, C} => B}}
    end.

pen(_H, none, _W, _D, T) -> {?wxTRANSPARENT_PEN, T};
pen(H, C, W, D, T) ->
    K = {pen, C, W, D},
    case maps:find(K, T) of
	{ok, P} -> {P, T};
	error ->
	    Style = case D of true -> ?wxPENSTYLE_SHORT_DASH; false -> ?wxPENSTYLE_SOLID end,
	    P = wxPen:new(candid_wx:tc(H, C, fg), [{width, W}, {style, Style}]),
	    {P, T#{K => P}}
    end.

%%% ------------------------------------------------------------ painting

%% The classes and texts that changed: [Id, Class ...], [Id, Text ...].
%% Frozen and batched, as rungs/5.
paint(_H, _Hd, [], []) -> ok;
paint(H, Hd = #{box := Box}, Cs, Ts) ->
    wxWindow:freeze(Box),
    try wx:batch(fun() -> paint1(H, Hd, Cs, Ts) end)
    after wxWindow:thaw(Box)
    end.

paint1(H, Hd, Cs, Ts) ->
    classes(H, Hd, Cs),
    texts(H, Ts),
    Ts =/= [] andalso wxWindow:layout(maps:get(top, Hd)),
    ok.

%% A window is coloured in the scope it was registered in, so it goes with
%% the rest of it (candid_wx:in_scope/3).
classes(H, Hd, [Id, C | T]) ->
    case candid_wx:lookup_scope(H, Id) of
	{ok, What, Scope} ->
	    candid_wx:in_scope(H, Scope, fun() ->
						 style(H, What, string:lexemes(C, " "), Hd)
					 end);
	error -> ok
    end,
    classes(H, Hd, T);
classes(_H, _Hd, []) -> ok.

texts(H, [Id, Txt | T]) ->
    case candid_wx:lookup(H, Id) of
	{ok, {text, W}} -> candid_wx:label(W, flat(Txt));
	_ -> ok
    end,
    texts(H, T);
texts(_H, []) -> ok.

style(H, {frame, F}, Cls, Hd) ->
    frame(H, F, Cls, [{"sgt", want}, {"sgf", unwant}], Hd);
style(H, {cell, G, R, C}, Cls, Hd) ->
    {Bg, Fg} = case {lists:member("bad", Cls), lists:member("cur", Cls),
		     lists:member("any", Cls)} of
		   {true, _, _} -> {fill(unwant, Hd), ink(unwant, Hd)};
		   {_, true, _} -> {fill(want, Hd), {238, 238, 238}};
		   {_, _, true} -> {{24, 24, 24}, {85, 85, 85}};
		   _            -> {{24, 24, 24}, {187, 187, 187}}
	       end,
    wxGrid:setCellBackgroundColour(G, R, C, candid_wx:tc(H, Bg)),
    wxGrid:setCellTextColour(G, R, C, candid_wx:tc(H, Fg, fg)),
    wxGrid:forceRefresh(G);
style(_H, {grid, G}, Cls, _Hd) ->
    wxWindow:show(G, [{show, not lists:member("hid", Cls)}]),
    candid_wx:relayout_up(wxWindow:getParent(G));
style(_H, _What, _Cls, _Hd) ->
    ok.

%% The frame's colour is the mark: the first of Marks the classes carry.
frame(H, F, Cls, Marks, Hd) ->
    Col = case [K || {Cl, K} <- Marks, lists:member(Cl, Cls)] of
	      [K | _] -> c(K, Hd);
	      []      -> ?BG
	  end,
    candid_wx:bg(H, F, Col),
    wxWindow:refresh(F).

c(K, #{colours := C}) -> candid_wx:colour(maps:get(K, C)).
fill(K, Hd) -> candid_wx:mix(c(K, Hd), 25, {17, 17, 17}).
ink(K, Hd)  -> candid_wx:mix(c(K, Hd), 35, {255, 255, 255}).

%% The goal the marks add up to, or none.
goal(H, Hd = #{goal := G, goal_frame := F}, none) ->
    candid_wx:label(G, "goal: click a contact -- holds, does not, forget"),
    candid_wx:fg(H, G, {136, 136, 136}),
    candid_wx:bg(H, F, ?BG),
    wxWindow:refresh(F),
    _ = Hd,
    ok;
goal(H, Hd = #{goal := G, goal_frame := F}, Text) ->
    candid_wx:label(G, "goal: " ++ Text),
    candid_wx:fg(H, G, {238, 238, 238}),
    candid_wx:bg(H, F, c(want, Hd)),
    wxWindow:refresh(F),
    wxWindow:layout(wxWindow:getParent(F)).

%% varp's answer, and with a trace found its buttons, the line the walk
%% writes (tr_ev) and the table (tr_tab), a cell per step and column.
answer(H, Hd = #{res := T, extra := Extra}, Cls, Text, Trace) ->
    candid_wx:label(T, flat(Text)),
    candid_wx:fg(H, T, case Cls of
					"ok"  -> c(true, Hd);
					"bad" -> c(unwant, Hd);
					_     -> {170, 170, 170}
				    end),
    wxStaticText:wrap(T, 900),
    candid_wx:forget(H, answer),
    wxWindow:destroyChildren(Extra),
    candid_wx:in_scope(H, answer, fun() -> trace_bar(H, Extra, Trace) end),
    candid_wx:relayout_up(Extra).

trace_bar(H, Extra, Trace) ->
    ES = wxWindow:getSizer(Extra),
    case Trace of
	none -> ok;
	{Rows, M, Names} ->
	    Bar = wxBoxSizer:new(?wxHORIZONTAL),
	    Pid = self(),
	    [begin
		 B = candid_wx:btn(H, Extra,
				   case Tag of
				       "rstep" -> "step";
				       "up"    -> "\x{25B2}";
				       "down"  -> "\x{25BC}";
				       _       -> Tag
				   end,
				   #{click => fun() -> Pid ! {candid_wx, {code, Tag}} end}),
		 wxSizer:add(Bar, B, [])
	     end || Tag <- ["up", "down", "live", "table", "replay", "rstep"]],
	    Ev = candid_wx:text(H, Extra, "", {170, 170, 170}),
	    candid_wx:register(H, "tr_ev", {text, Ev}, answer),
	    wxSizer:add(Bar, Ev, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
				  {border, 8}]),
	    wxSizer:add(ES, Bar, [{flag, ?wxTOP}, {border, 4}]),
	    G = table(H, Extra, Rows, M, Names),
	    wxSizer:add(ES, G, [{flag, ?wxTOP}, {border, 4}])
    end.

table(H, Parent, Rows, M = #{states := Sts}, Names) ->
    Cols = csp_code:cols(Rows),
    Steps = lists:seq(0, length(Rows) - 1),
    G = wxGrid:new(Parent, ?wxID_ANY),
    wxGrid:createGrid(G, length(Cols), length(Steps)),
    wxGrid:enableEditing(G, false),
    wxGrid:setDefaultCellFont(G, candid_wx:font(H)),
    wxGrid:setDefaultCellBackgroundColour(G, {24, 24, 24}),
    wxGrid:setDefaultCellTextColour(G, {187, 187, 187}),
    [wxGrid:setColLabelValue(G, I, integer_to_list(I)) || I <- Steps],
    [begin
	 wxGrid:setRowLabelValue(G, R, csp_code:col_name(C)),
	 [begin
	      V = csp_code:signed(C, proplists:get_value(C, Row), M),
	      wxGrid:setCellValue(G, R, I, cell(C, V, Sts, Names)),
	      candid_wx:register(H, csp_code:tr_id(C, I), {cell, G, R, I}, answer)
	  end || {I, Row} <- lists:zip(Steps, Rows)]
     end || {R, C} <- enum(Cols)],
    candid_wx:register(H, "tr_tab", {grid, G}, answer),
    wxGrid:autoSize(G),
    wxWindow:hide(G),
    G.

cell(_C, '-', _Sts, _Names) -> "-";
cell("St", V, Sts, Names) ->
    case lists:keyfind(V, 2, Sts) of
	{N, V} -> N;
	false  -> maps:get(V, Names, integer_to_list(V))
    end;
cell(_C, V, _Sts, _Names) when is_integer(V) -> integer_to_list(V);
cell(_C, V, _Sts, _Names) -> flat(V).

flat(T) -> lists:flatten(io_lib:format("~ts", [lists:flatten(T)])).

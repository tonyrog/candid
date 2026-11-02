%%% The code view's renderer for the desktop: csp_code decides what the view
%%% shows, this builds it out of wx widgets and lights them.
%%%
%%% The contract is csp_code_wse's -- the ids and the classes, see there. A
%%% rung is nested sizers, the way the html is nested flex boxes: an AND runs
%%% across, an OR stacks its branches in a box of their own. A contact is a
%%% text in a frame, the frame's colour being the mark, since wx has no
%%% outline. Every piece is registered by its id (candid_wx:register/4), so
%%% paint/4 finds it by name as the browser does.

-module(csp_code_wx).

-include_lib("wx/include/wx.hrl").

-export([new/4, shown/3, rungs/5, paint/4, goal/3, answer/5]).

-define(BG, {18, 18, 18}).
-define(WIRE, {102, 102, 102}).

%% The view, hidden, with its tab buttons; the model frame (goal, clear,
%% solve, k) in the top frame's status row, the answer and the program's own
%% values below. See csp_code_wse:new/4 for what is sent on its events.
new(H, Where, Tabs, #{colours := Colours, ks := Ks, k := K0}) ->
    #{code := Right, status := {Top, Row}, top := {Top, TopS}} = Where,
    Box = wxPanel:new(Right),
    BoxS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Box, BoxS),
    Bar = wxBoxSizer:new(?wxHORIZONTAL),
    Btns = case Tabs of
	       [_] -> [];
	       _ ->
		   [begin
			B = wxToggleButton:new(Box, ?wxID_ANY, Name),
			wxToggleButton:connect(B, command_togglebutton_clicked,
					       [{userData, {code, "tab=" ++
								integer_to_list(I)}}]),
			wxSizer:add(Bar, B, [{flag, ?wxRIGHT}, {border, 4}]),
			B
		    end || {I, #{name := Name}} <- enum(Tabs)]
	   end,
    wxSizer:add(BoxS, Bar, [{flag, ?wxBOTTOM}, {border, 8}]),
    Body = wxPanel:new(Box),
    wxWindow:setSizer(Body, wxBoxSizer:new(?wxVERTICAL)),
    wxSizer:add(BoxS, Body, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxSizer:add(wxWindow:getSizer(Right), Box, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxWindow:hide(Box),
    %% The model frame.
    {GoalF, Goal} = candid_wx:frame_box(Top, "goal"),
    wxWindow:setFont(Goal, candid_wx:font(H)),
    wxWindow:setMinSize(Goal, {320, -1}),
    wxSizer:add(Row, GoalF, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
			     {border, 12}]),
    [begin
	 B = wxButton:new(Top, ?wxID_ANY, [{label, L}]),
	 wxButton:connect(B, command_button_clicked, [{userData, {code, L}}]),
	 wxSizer:add(Row, B, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
			      {border, 4}])
     end || L <- ["clear", "solve"]],
    Sel = wxChoice:new(Top, ?wxID_ANY,
		       [{choices, ["k \x{2264} " ++ integer_to_list(K) || K <- Ks]}]),
    wxChoice:setSelection(Sel, length(lists:takewhile(fun(K) -> K =/= K0 end, Ks))),
    wxChoice:connect(Sel, command_choice_selected,
		     [{userData, {code_choice, "k=", [integer_to_list(K) || K <- Ks]}}]),
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
    #{box => Box, body => Body, right => Right, top => Top,
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

%% Tab I's rungs, drawn as ladder or code.
rungs(H, Hd = #{body := Body, right := Right, tab_buttons := Btns}, Mode, I, Tab) ->
    [wxToggleButton:setValue(B, J =:= I) || {J, B} <- enum(Btns)],
    candid_wx:forget(H, rung),
    wxWindow:destroyChildren(Body),
    BS = wxWindow:getSizer(Body),
    head(H, Body, BS, Tab),
    Ctx = #{env => maps:get(env, Tab), prefix => maps:get(prefix, Tab), hd => Hd},
    lists:foldl(fun(R, G) -> row(H, Body, BS, R, G, Mode, Ctx) end, 0,
		maps:get(rules, Tab)),
    wxWindow:layout(Body),
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

row(H, Body, BS, {gate, 'end', _}, G, _Mode, _Ctx) ->
    T = candid_wx:text(H, Body, "#end", {68, 85, 102}),
    wxSizer:add(BS, T, [{flag, ?wxBOTTOM}, {border, 8}]),
    G;
row(H, Body, BS, {gate, Kind, Arg}, G, _Mode, _Ctx) ->
    Txt = case Kind of
	      in     -> ["#in ", lists:join(" ", Arg)];
	      'when' -> ["#when ", candyspeak_eval:text(Arg)]
	  end,
    T = candid_wx:text(H, Body, flat(Txt), {102, 136, 170}),
    candid_wx:register(H, "g" ++ integer_to_list(G), {hd, T}, rung),
    wxSizer:add(BS, T, [{flag, ?wxTOP}, {border, 10}]),
    G + 1;
row(H, Body, BS, R = #{no := N, line := Ln, guard := Gd, assigns := As}, G,
    Mode, Ctx) ->
    K = "k" ++ integer_to_list(N),
    P = wxPanel:new(Body),
    S = wxBoxSizer:new(?wxHORIZONTAL),
    wxWindow:setSizer(P, S),
    LnT = candid_wx:text(H, P, integer_to_list(Ln), {85, 85, 85}),
    wxWindow:setMinSize(LnT, {40, -1}),
    wxSizer:add(S, LnT, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    Label = case {Mode, R} of
		{ladder, #{coil := Tgt}} -> candyspeak_eval:text(Tgt);
		{code, #{coil := Tgt}}   -> [candyspeak_eval:text(Tgt), " ="];
		_ -> lists:join(", ", [csp_code:assign(A) || A <- As])
	    end,
    Coil = fun() ->
		   {F, T} = candid_wx:frame_box(P, flat(Label)),
		   wxWindow:setFont(T, candid_wx:font(H)),
		   candid_wx:register(H, K, {coil, F, T}, rung),
		   F
	   end,
    Add = fun(W) -> wxSizer:add(S, W, [{flag, ?wxALIGN_CENTER_VERTICAL}]) end,
    case {Mode, Gd} of
	{ladder, undefined} ->
	    Add(wire(H, P, 4)), Add(Coil());
	{ladder, _} ->
	    Add(wire(H, P, 1)),
	    {L, _} = ladder(H, P, Gd, K, 0, Ctx),
	    wxSizer:add(S, L, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
	    Add(wire(H, P, 1)), Add(Coil());
	{code, undefined} ->
	    Add(Coil());
	{code, _} ->
	    Add(Coil()),
	    case R of
		#{coil := _} -> ok;
		_ -> Add(candid_wx:text(H, P, " ? ", {119, 119, 119}))
	    end,
	    {T, _} = code(H, P, Gd, K, 0, 0, Ctx),
	    wxSizer:add(S, T, [{flag, ?wxALIGN_CENTER_VERTICAL}])
    end,
    candid_wx:register(H, "r" ++ integer_to_list(N), {row, P, LnT}, rung),
    wxSizer:add(BS, P, [{flag, ?wxTOP}, {border, 3}]),
    G.

wire(H, P, N) ->
    candid_wx:text(H, P, lists:duplicate(N, $\x{2500}), ?WIRE).

%% AND across, OR down. Returns {Sizer, NextContact}.
ladder(H, P, X = {'&&', _, _, _}, K, I, Ctx) ->
    S = wxBoxSizer:new(?wxHORIZONTAL),
    I1 = lists:foldl(fun(C, J) ->
			     J =/= I andalso
				 wxSizer:add(S, wire(H, P, 1),
					     [{flag, ?wxALIGN_CENTER_VERTICAL}]),
			     {W, J1} = ladder(H, P, C, K, J, Ctx),
			     wxSizer:add(S, W, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
			     J1
		     end, I, csp_code:chain('&&', X)),
    {S, I1};
ladder(H, P, X = {'||', _, _, _}, K, I, Ctx) ->
    S = wxStaticBoxSizer:new(?wxVERTICAL, P),
    I1 = lists:foldl(fun(C, J) ->
			     B = wxBoxSizer:new(?wxHORIZONTAL),
			     {W, J1} = ladder(H, P, C, K, J, Ctx),
			     wxSizer:add(B, W, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
			     wxSizer:add(S, B, [{flag, ?wxALL}, {border, 1}]),
			     J1
		     end, I, csp_code:chain('||', X)),
    {S, I1};
ladder(H, P, X, K, I, Ctx) ->
    {contact(H, P, X, K, I, Ctx), I + 1}.

%% The same walk as text: the contacts in order, the operators between.
code(H, P, X = {Op, _, _, _}, K, I, Pr, Ctx) when Op =:= '&&'; Op =:= '||' ->
    Q = case Op of '||' -> 1; '&&' -> 2 end,
    S = wxBoxSizer:new(?wxHORIZONTAL),
    Txt = fun(T) -> wxSizer:add(S, candid_wx:text(H, P, T, {119, 119, 119}),
				[{flag, ?wxALIGN_CENTER_VERTICAL}]) end,
    Q < Pr andalso Txt("("),
    I1 = lists:foldl(fun(C, J) ->
			     J =/= I andalso Txt(" " ++ atom_to_list(Op) ++ " "),
			     {W, J1} = code(H, P, C, K, J, Q + 1, Ctx),
			     wxSizer:add(S, W, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
			     J1
		     end, I, csp_code:chain(Op, X)),
    Q < Pr andalso Txt(")"),
    {S, I1};
code(H, P, X, K, I, _Pr, Ctx) ->
    {contact(H, P, X, K, I, Ctx), I + 1}.

%% A contact. A click marks it, see csp_code:control/2.
contact(H, P, X, K, I, _Ctx) ->
    Id = K ++ "_" ++ integer_to_list(I),
    {F, T} = candid_wx:frame_box(P, flat(candyspeak_eval:text(X))),
    wxWindow:setFont(T, candid_wx:font(H)),
    candid_wx:click(T, {code, "ct=" ++ Id}, self()),
    candid_wx:register(H, Id, {contact, F, T}, rung),
    F.

%%% ------------------------------------------------------------ painting

%% The classes and texts that changed: [Id, Class ...], [Id, Text ...].
paint(H, Hd, Cs, Ts) ->
    classes(H, Hd, Cs),
    texts(H, Ts),
    Ts =/= [] andalso wxWindow:layout(maps:get(top, Hd)),
    ok.

classes(H, Hd, [Id, C | T]) ->
    case candid_wx:lookup(H, Id) of
	{ok, What} -> style(H, What, string:lexemes(C, " "), Hd);
	error      -> ok
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

style(H, {contact, F, T}, Cls, Hd) ->
    {Bg, Fg} = case {lists:member("t", Cls), lists:member("u", Cls)} of
		   {true, _} -> {fill(true, Hd), ink(true, Hd)};
		   {_, true} -> {{30, 30, 30}, {102, 102, 102}};
		   _         -> {{30, 30, 30}, {153, 153, 153}}
	       end,
    colours(H, T, Bg, Fg),
    frame(H, F, Cls, [{"mt", want}, {"mf", unwant}], Hd);
style(H, {coil, F, T}, Cls, Hd) ->
    case lists:member("on", Cls) of
	true  -> colours(H, T, fill(fired, Hd), ink(fired, Hd));
	false -> colours(H, T, ?BG, {153, 153, 153})
    end,
    frame(H, F, Cls, [{"nx", next}], Hd);
style(H, {row, P, Ln}, Cls, _Hd) ->
    Off = lists:member("off", Cls),
    colours(H, P, case Off of true -> {10, 10, 10}; false -> ?BG end, {187, 187, 187}),
    colours(H, Ln, case Off of true -> {10, 10, 10}; false -> ?BG end,
	    case Off of true -> {51, 51, 51}; false -> {85, 85, 85} end);
style(H, {hd, T}, Cls, Hd) ->
    candid_wx:fg(H, T, case lists:member("t", Cls) of
					true  -> c(block, Hd);
					false -> {102, 136, 170}
				    end),
    wxWindow:refresh(T);
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
    wxGrid:setCellTextColour(G, R, C, candid_wx:tc(H, Fg)),
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

colours(H, W, Bg, Fg) ->
    candid_wx:bg(H, W, Bg),
    candid_wx:fg(H, W, Fg),
    wxWindow:refresh(W).

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
    ES = wxWindow:getSizer(Extra),
    case Trace of
	none -> ok;
	{Rows, M, Names} ->
	    Bar = wxBoxSizer:new(?wxHORIZONTAL),
	    [begin
		 B = wxButton:new(Extra, ?wxID_ANY,
				  [{label, case Tag of
					       "rstep" -> "step";
					       "up"    -> "\x{25B2}";
					       "down"  -> "\x{25BC}";
					       _       -> Tag
					   end}]),
		 wxButton:connect(B, command_button_clicked, [{userData, {code, Tag}}]),
		 wxSizer:add(Bar, B, [{flag, ?wxRIGHT}, {border, 4}])
	     end || Tag <- ["up", "down", "live", "table", "replay", "rstep"]],
	    Ev = candid_wx:text(H, Extra, "", {170, 170, 170}),
	    candid_wx:register(H, "tr_ev", {text, Ev}, answer),
	    wxSizer:add(Bar, Ev, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
				  {border, 8}]),
	    wxSizer:add(ES, Bar, [{flag, ?wxTOP}, {border, 4}]),
	    G = table(H, Extra, Rows, M, Names),
	    wxSizer:add(ES, G, [{flag, ?wxTOP}, {border, 4}])
    end,
    candid_wx:relayout_up(Extra).

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

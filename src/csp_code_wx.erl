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

-export([zoom_at/5, wheel/4, ops/1, ops/3, paint_ops/3]).   % the tests, the bench
-export([new/4, metrics/2, shown/3, rungs/6, draw/3, paint/4, answer/5]).
-export([edit_status/3, see/4]).

-define(BG, {18, 18, 18}).
-define(ZOOMS, [2.0, 1.0, 0.75, 0.5, 0.25]).   % the zoom menu's

%% The view, hidden, with its tab buttons; what was clicked in the top
%% frame's status row, a trace from the solver and the program's own values
%% below. See csp_code_wse:new/4 for what is sent on its events.
new(H, Where, Tabs, Opts) -> wx:batch(fun() -> new1(H, Where, Tabs, Opts) end).

new1(H, Where, Tabs, #{colours := Colours}) ->
    #{code := Right, head := TabsP, status := {Top, _}, top := {Top, TopS}} = Where,
    Box = wxPanel:new(Right),
    BoxS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Box, BoxS),
    %% The tabs and the zoom: right over the rungs, where they stay when the
    %% rungs are scrolled (candid_wx's code head).
    candid_wx:forget(H, code_head),           % their entries before them
    wxWindow:destroyChildren(TabsP),
    %% Two rows: the zoom and the editor's status line; under them the tabs,
    %% only when the program has objects to have tabs for.
    Col = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(TabsP, Col),
    Bar1 = wxBoxSizer:new(?wxHORIZONTAL),
    Bar = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Col, Bar1, []),
    Pid = self(),
    Btns = case Tabs of
	       [_] -> [];
	       _ ->
		   [begin
			Tab = "tab=" ++ integer_to_list(I),
			B = candid_wx:in_scope(
			      H, code_head,
			      fun() ->
				      candid_wx:btn(H, TabsP, Name,
						    #{click => fun() -> Pid ! {candid_wx, {code, Tab}}
							       end})
			      end),
			wxSizer:add(Bar, B, []),
			B
		    end || {I, #{name := Name}} <- enum(Tabs)]
	   end,
    Body = wxPanel:new(Box),
    wxWindow:setSizer(Body, wxBoxSizer:new(?wxVERTICAL)),
    wxSizer:add(BoxS, Body, []),
    Canvas = canvas(H, Box, Right),
    candid_wx:register(H, code_canvas, {Canvas, Right}, perm),
    %% The zoom is the canvas's right-click menu (zoom_menu), and ctrl +
    %% wheel, ctrl + up/down at the mouse, ctrl + 0 for 100 %.
    %% The editor's status line: here, over the canvas, where it stays in
    %% sight however far the rungs are scrolled.
    EdS = candid_wx:in_scope(H, code_head,
			     fun() -> candid_wx:text(H, TabsP, "", {200, 200, 200}) end),
    wxSizer:add(Bar1, EdS, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    Btns =:= [] orelse wxSizer:add(Col, Bar, [{flag, ?wxTOP}, {border, 4}]),
    wxSizer:add(BoxS, Canvas, []),
    wxSizer:add(wxWindow:getSizer(Right), Box, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxWindow:hide(Box),
    %% A trace from the solver (csp_solve): what it is, and the step tool.
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
    #{box => Box, tabs_panel => TabsP, body => Body, canvas => Canvas, right => Right, top => Top,
      ed_status => EdS,
      tab_buttons => Btns, event => code, res => ResT, extra => Extra, colours => Colours}.

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).

%% The values with no widget of their own: a cell each, its name a signal to
%% mark by click, a #local in italics. By name; every name its whole width --
%% measured in the font it is shown in, which frame_box's label did not have
%% yet when it was sized, and was cut -- and as many columns as fit.
vals(_H, _Parent, _Sizer, _Pre, _Obj, [], _Scope) -> ok;
vals(H, Parent, Sizer, Pre, Obj, Vars0, Scope) ->
    Vars = lists:sort(fun({_, A}, {_, B}) -> A =< B end, Vars0),
    Font = candid_wx:font(H),
    NameW = lists:max([text_w(Parent, N, Font) || {_, N} <- Vars]) + 8,
    G = wxGridSizer:new(0, cols(H, Parent, NameW + 86), 2, 2),
    [begin
	 Full = case Obj of none -> N; _ -> Obj ++ "." ++ N end,
	 Cell = wxBoxSizer:new(?wxHORIZONTAL),
	 {F, T} = candid_wx:frame_box(Parent, N),
	 wxWindow:setFont(T, Font),
	 wxWindow:setMinSize(T, {text_w(Parent, N, Font), -1}),
	 wxWindow:setMinSize(F, {NameW, -1}),
	 candid_wx:fg(H, T, case K of local -> {136, 170, 187};
						   var -> {136, 136, 136} end),
	 candid_wx:register(H, "sv_" ++ Full, {frame, F}, Scope),
	 V = candid_wx:text(H, Parent, "", {221, 221, 221}),
	 wxWindow:setMinSize(V, {70, -1}),
	 candid_wx:register(H, Pre ++ N, {text, V}, Scope),
	 wxSizer:add(Cell, F, [{proportion, 1}]),
	 wxSizer:add(Cell, V, [{flag, ?wxLEFT bor ?wxALIGN_CENTER_VERTICAL},
			       {border, 6}]),
	 wxSizer:add(G, Cell, [{flag, ?wxEXPAND}])
     end || {K, N} <- Vars],
    case Pre of
	"m_" -> foldable(H, Parent, Sizer, G, length(Vars));
	_ -> wxSizer:add(Sizer, G, [{flag, ?wxALL}, {border, 4}])
    end.

text_w(Win, Text, Font) ->
    {W, _, _, _} = wxWindow:getTextExtent(Win, Text, [{theFont, Font}]),
    W.

%% As many cells across as the panel has room for, one to eight. The panel
%% may not be laid out yet; the window is, and the program column is beside.
cols(H, Parent, CellW) ->
    {PW, _} = wxWindow:getClientSize(Parent),
    {FW, _} = wxWindow:getClientSize(maps:get(frame, H)),
    Avail = max(PW, FW - 480),
    max(1, min(8, Avail div CellW)).

%% The main values under a heading that folds them away: a program with
%% forty of them had no room left for its rungs. Open or not is kept with
%% the settings (candid:pref(values)), for the next window and the next run.
foldable(H, Parent, Sizer, G, N) ->
    Open = candid:pref(values) =/= "closed",
    Label = fun(true) -> "values (" ++ integer_to_list(N) ++ ") \x{25BE}";
	       (false) -> "values (" ++ integer_to_list(N) ++ ") \x{25B8}"
	    end,
    Pid = self(),
    Ids = maps:get(ids, H),
    %% In the panel's id table, which the click's callback can reach: the
    %% button, and whether the values are folded away.
    Toggle = fun() ->
		     Show = ets:member(Ids, values_shut),
		     case Show of
			 true -> ets:delete(Ids, values_shut);
			 false -> ets:insert(Ids, {values_shut, x, perm})
		     end,
		     wxSizer:show(Sizer, G, [{show, Show}]),
		     [{_, Btn, _}] = ets:lookup(Ids, values_btn),
		     candid_wx:btn_label(H, Btn, Label(Show)),
		     candid_wx:relayout_up(Parent),
		     Pid ! {candid_wx, {code, "values=" ++ case Show of
								true -> "open";
								false -> "closed"
							    end}}
	     end,
    B = candid_wx:btn(H, Parent, Label(Open), #{click => Toggle}),
    ets:insert(Ids, {values_btn, B, perm}),
    wxSizer:add(Sizer, B, [{flag, ?wxLEFT bor ?wxTOP}, {border, 4}]),
    wxSizer:add(Sizer, G, [{flag, ?wxALL}, {border, 4}]),
    Open orelse begin
		    ets:insert(Ids, {values_shut, x, perm}),
		    wxSizer:show(Sizer, G, [{show, false}])
		end,
    ok.

shown(_H, #{box := Box, right := Right, tabs_panel := T}, Show) ->
    wxWindow:show(Box, [{show, Show}]),
    wxWindow:show(T, [{show, Show}]),
    candid_wx:relayout_up(T),
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
    store(H, []),
    candid_wx:register(H, code_size, Size, perm),
    size(H, C),
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
%%%
%%% ZOOM is the renderer's alone: csp_code lays out and hit-tests at 100 %,
%%% the canvas is drawn scaled (setUserScale) and as big as that, and a
%%% click is scaled back. Ctrl + wheel, or ctrl + up/down once the canvas
%%% has the focus (a click gives it), zooms at the mouse: the point under it
%%% stays there. Ctrl + 0 is 100 % again.


canvas(H, Parent, Right) ->
    C = wxPanel:new(Parent, [{style, ?wxFULL_REPAINT_ON_RESIZE bor ?wxWANTS_CHARS}]),
    wxWindow:setFont(C, candid_wx:font(H)),
    wxWindow:setBackgroundStyle(C, ?wxBG_STYLE_PAINT),
    {_, Line, _, _} = wxWindow:getTextExtent(C, "M"),
    Pid = self(),
    %% Only what is to be drawn again: a long program's canvas is many
    %% screens tall, and a buffer of all of it, drawn whole, was seconds a
    %% paint. GTK double-buffers the window itself. The ops are kept by
    %% the bands they cross (see draw/3); a paint takes those it shows.
    candid_wx:register(H, code_index, ets:new(code_index, [ordered_set, public]), perm),
    wxPanel:connect(C, paint, [{callback,
				fun(_E, _O) ->
					DC = wxPaintDC:new(C),
					Box = wxRegion:getBox(wxWindow:getUpdateRegion(C)),
					wx:batch(fun() -> paint_ops(H, DC, Box) end),
					wxPaintDC:destroy(DC)
				end}]),
    Ids = maps:get(ids, H),
    wxPanel:connect(C, left_down, [{callback,
				    fun(#wx{event = #wxMouse{x = X, y = Y}}, O) ->
					    Z = zoom(H),
					    wxWindow:setFocus(C),
					    ets:insert(Ids, {code_press, {X, Y}, perm}),
					    Pid ! {candid_wx, {code, xy(trunc(X / Z),
									trunc(Y / Z))}},
					    wxEvent:skip(O)
				    end}]),
    %% For the editor (csp_code's edit): a double click, a drag -- the rest
    %% of the view takes no notice of either -- and a key.
    wxPanel:connect(C, left_dclick, [{callback,
				      fun(#wx{event = #wxMouse{x = X, y = Y}}, O) ->
					      Z = zoom(H),
					      Pid ! {candid_wx, {code, "d" ++ xy(trunc(X / Z),
										trunc(Y / Z))}},
					      wxEvent:skip(O)
				      end}]),
    wxPanel:connect(C, left_up, [{callback,
				  fun(#wx{event = #wxMouse{x = X, y = Y}}, O) ->
					  Z = zoom(H),
					  case ets:lookup(Ids, code_press) of
					      [{_, {X0, Y0}, _}] when abs(X - X0) > 4;
								      abs(Y - Y0) > 4 ->
						  Pid ! {candid_wx,
							 {code, lists:flatten(
								  io_lib:format("sel=~w,~w,~w,~w",
										[trunc(V / Z) || V <- [X0, Y0, X, Y]]))}};
					      _ -> ok
					  end,
					  ets:delete(Ids, code_press),
					  wxEvent:skip(O)
				  end}]),
    [wxPanel:connect(C, Ev, [{callback,
                              fun(_E, O) ->
                                      Pid ! {candid_wx, {code, case Ev of
                                                                   set_focus -> "focus=on";
                                                                   kill_focus -> "focus=off"
                                                               end}},
                                      wxEvent:skip(O)
                              end}]) || Ev <- [set_focus, kill_focus]],
    %% The keys by the table (caned_keys), the settings' {keys, ...} over
    %% the defaults; a sequence's first keys wait in the id table
    %% (code_pending). Before a page up or down, how many rows a page is.
    Keys = caned_keys:settings(),
    Key = fun(Cmd) ->
		  (Cmd =:= page_up orelse Cmd =:= page_down) andalso page(H, Right, Line, Pid),
		  Pid ! {candid_wx, {code, {key, Cmd}}}
	  end,
    wxPanel:connect(C, char, [{callback,
			       fun(#wx{event = K = #wxKey{}}, O) ->
				       P = case ets:lookup(Ids, code_pending) of
					       [{_, P0, _}] -> P0;
					       [] -> []
					   end,
				       ets:delete(Ids, code_pending),
				       case caned_keys:feed(caned_keys:name(K), P, Keys) of
					   {command, none} when P =:= [] -> wxEvent:skip(O);
					   {command, none} -> Key({msg, ""});
					   {command, Cmd} -> Key(Cmd);
					   {prefix, P1} ->
					       ets:insert(Ids, {code_pending, P1, perm}),
					       Key({msg, lists:flatten(lists:join(" ", P1)) ++ "-"});
					   {undefined, Seq} -> Key({msg, Seq ++ " is undefined"})
				       end
			       end}]),
    wxPanel:connect(C, right_down, [{callback,
                                     fun(#wx{event = #wxMouse{x = X, y = Y}}, _O) ->
                                             zoom_menu(H, C, Right, {X, Y})
                                     end}]),
    wxPanel:connect(C, mousewheel,
		    [{callback,
		      fun(#wx{event = #wxMouse{controlDown = true, x = X, y = Y,
					       wheelRotation = R}}, _O) when R =/= 0 ->
			      zoom_at(H, C, Right, step(zoom(H), R), {X, Y});
			 (#wx{event = #wxMouse{shiftDown = false, wheelRotation = R,
					       wheelDelta = D, linesPerAction = L}}, _O) ->
			      wheel(H, C, Right, -R * max(1, L) * Line div max(1, D));
			 (_E, O) -> wxEvent:skip(O)
		      end}]),
    wxPanel:connect(C, key_down,
		    [{callback,
		      fun(#wx{event = #wxKey{controlDown = true, keyCode = K}}, O) ->
			      Z = zoom(H),
			      case K of
				  ?WXK_UP   -> zoom_at(H, C, Right, step(Z, 1), mouse(C, Right));
				  ?WXK_DOWN -> zoom_at(H, C, Right, step(Z, -1), mouse(C, Right));
				  $0        -> zoom_at(H, C, Right, 1.0, mouse(C, Right));
				  _         -> wxEvent:skip(O)
			      end;
			 (_E, O) -> wxEvent:skip(O)
		      end}]),
    C.

%% A page: the rows of the editor (6 px over the font's) the view shows.
page(H, Right, Line, Pid) ->
    {_, Rh} = wxWindow:getClientSize(Right),
    Pid ! {candid_wx, {code, "page=" ++ integer_to_list(
                                         max(1, trunc(Rh / zoom(H) / (Line + 6)) - 2))}}.

%% The wheel, Px pixels down (the rows of a notch). wx scrolled 15 px a
%% notch and drew the view for each, and a turned wheel ran ahead of the
%% drawing. Here the turns add up while a scroll is drawn and are scrolled
%% together: one process scrolls, and draws, while there is any to do.
wheel(H, C, Right, Px) ->
    Ids = maps:get(ids, H),
    Z = zoom(H),
    ets:update_counter(Ids, code_wheel, {2, round(Px * Z)}, {code_wheel, 0, perm}),
    ets:insert_new(Ids, {code_wheeling, true, perm}) andalso
        begin
            Env = maps:get(env, H),
            spawn(fun() -> wx:set_env(Env), wheeling(Ids, C, Right) end)
        end,
    ok.

wheeling(Ids, C, Right) ->
    case ets:take(Ids, code_wheel) of
        [{_, Px, _}] ->
            {_, Uy} = wxScrolledWindow:getScrollPixelsPerUnit(Right),
            {_, Vy} = wxScrolledWindow:getViewStart(Right),
            Uy > 0 andalso
                wxScrolledWindow:scroll(Right, -1, max(0, Vy + Px div Uy)),
            wxWindow:update(C),
            wheeling(Ids, C, Right);
        [] ->
            ets:delete(Ids, code_wheeling),
            %% a turn between the take and the delete found it busy
            ets:member(Ids, code_wheel) andalso
                ets:insert_new(Ids, {code_wheeling, true, perm}) andalso
                wheeling(Ids, C, Right),
            ok
    end.

%% The zoom, a menu where the canvas is right-clicked, the point there kept
%% where it is. Opened by a process of its own, not in the callback:
%% popupMenu is modal (see candid_wx:menu_btn).
zoom_menu(H, C, Right, At) ->
    Env = maps:get(env, H),
    Z = zoom(H),
    spawn(fun() ->
                  wx:set_env(Env),
                  M = wxMenu:new(),
                  [wxMenu:appendRadioItem(M, I, zoom_label(Zi))
                   || {I, Zi} <- lists:zip(lists:seq(1, length(?ZOOMS)), ?ZOOMS)],
                  wxMenu:check(M, index_of(Z, ?ZOOMS) + 1, true),
                  wxMenu:connect(M, command_menu_selected,
                                 [{callback, fun(#wx{id = I}, _) ->
                                                     zoom_at(H, C, Right, lists:nth(I, ?ZOOMS), At)
                                             end}]),
                  wxWindow:popupMenu(C, M),
                  wxMenu:destroy(M)
          end),
    ok.

zoom(H) ->
    case candid_wx:lookup(H, code_zoom) of
	{ok, Z} -> Z;
	error   -> 1.0
    end.

%% The next of the menu's values up (R > 0) or down.
step(Z, R) when R > 0 ->
    case [X || X <- ?ZOOMS, X > Z] of
	[] -> Z;
	Up -> lists:last(Up)
    end;
step(Z, _) ->
    case [X || X <- ?ZOOMS, X < Z] of
	[] -> Z;
	[Down | _] -> Down
    end.

zoom_label(Z) -> integer_to_list(round(Z * 100)) ++ " %".

index_of(X, L) -> length(lists:takewhile(fun(Y) -> Y =/= X end, L)).

%% The canvas as big as the picture at the zoom in force.
size(H, C) ->
    {W, Ht} = case candid_wx:lookup(H, code_size) of
		  {ok, S} -> S;
		  error   -> {0, 0}
	      end,
    Z = zoom(H),
    S1 = {round(W * Z), round(Ht * Z)},
    wxWindow:setMinSize(C, S1),
    wxWindow:setSize(C, S1).

%% Where the mouse is on the canvas; the middle of what is seen of it when
%% the mouse is somewhere else.
mouse(C, Right) ->
    {Mx, My} = wxWindow:screenToClient(C, wx_misc:getMousePosition()),
    {Ox, Oy} = in_right(C),
    {Rw, Rh} = wxWindow:getClientSize(Right),
    case Ox + Mx >= 0 andalso Ox + Mx < Rw andalso Oy + My >= 0 andalso Oy + My < Rh of
	true  -> {Mx, My};
	false -> {Rw div 2 - Ox, Rh div 2 - Oy}
    end.

%% The canvas's top left in Right's window, as it is scrolled now.
in_right(C) ->
    Box = wxWindow:getParent(C),
    {Cx, Cy} = wxWindow:getPosition(C),
    {Bx, By} = wxWindow:getPosition(Box),
    {Bx + Cx, By + Cy}.

%% Zoom to Z1 with the canvas point M (pixels, as it is drawn now) staying
%% where it is in Right's window -- across only when the view was scrolled
%% across: one at its left edge stays there, the code's start in sight.
zoom_at(H, C, Right, Z1, {Mx, My}) ->
    Z0 = zoom(H),
    {Ox, Oy} = in_right(C),
    {Ux, Uy} = wxScrolledWindow:getScrollPixelsPerUnit(Right),
    {Vx, Vy} = wxScrolledWindow:getViewStart(Right),
    %% The canvas's origin in Right's whole (scrolled) area, kept by a zoom.
    {Ax, Ay} = {Ox + Vx * Ux, Oy + Vy * Uy},
    {Px, Py} = {Mx / Z0, My / Z0},
    candid_wx:register(H, code_zoom, Z1, perm),
    wxWindow:freeze(Right),
    try
	size(H, C),
	wxWindow:layout(wxWindow:getParent(C)),
	wxWindow:layout(Right),
	wxScrolledWindow:fitInside(Right),
	X = case Vx of
		0 -> 0;
		_ -> Ax + round(Px * Z1) - (Ox + Mx)
	    end,
	Y = Ay + round(Py * Z1) - (Oy + My),
	wxScrolledWindow:scroll(Right, max(0, X) div max(1, Ux),
				max(0, Y) div max(1, Uy))
    after wxWindow:thaw(Right)
    end,
    wxWindow:refresh(C, [{eraseBackground, false}]).

xy(X, Y) -> "xy=" ++ integer_to_list(X) ++ "," ++ integer_to_list(Y).

%% The ops by band: {{Band, Seq}, Op} for each band of ?BAND rows of the
%% picture an op crosses -- most cross one, a branch or a box a few -- Seq
%% its place in the picture's list, which is the order they are drawn in.
-define(BAND, 256).

index(H) ->
    {ok, T} = candid_wx:lookup(H, code_index),
    T.

store(H, Ops) ->
    T = index(H),
    ets:delete_all_objects(T),
    ets:insert(T, [{{B, I}, Op} || {I, Op} <- lists:enumerate(Ops),
                                   {Y0, Y1} <- [span(Op)],
                                   B <- lists:seq(stripe(Y0), stripe(Y1))]).

span({rect, _, Y, _, Ht, _, _, _, _}) -> {Y, Y + Ht};
span({line, _, Ya, _, Yb, _, _, _}) -> {min(Ya, Yb), max(Ya, Yb)};
span({text, _, Y, _, _, _}) -> {Y, Y + 40}.

stripe(Y) -> floor(Y / ?BAND).

%% The ops crossing rows Y0..Y1, in their order, each once.
%% One walk from the first band's start to the last band's end; an op in
%% two of them met twice, kept once.
ops(H, Y0, Y1) ->
    [Op || {_, Op} <- lists:ukeysort(1, walk(index(H), {stripe(Y0), 0}, stripe(Y1), []))].

walk(T, K, B1, Acc) ->
    case ets:next_lookup(T, K) of
        {K1 = {B, I}, [{_, Op}]} when B =< B1 -> walk(T, K1, B1, [{I, Op} | Acc]);
        _ -> Acc
    end.

%% All of them, as draw/3 was given them (the tests).
ops(Ids) when not is_map(Ids) ->
    case ets:lookup(Ids, code_index) of
        [{_, T, _}] -> [Op || {_, Op} <- lists:usort([{I, Op} || {{_, I}, Op} <- ets:tab2list(T)])];
        [] -> []
    end.

%% The width of a character and the height of a line in the view's font.
metrics(_H, #{canvas := C}) ->
    {W, Ht, _, _} = wxWindow:getTextExtent(C, "MMMMMMMMMM"),
    #{cw => W / 10, ch => Ht}.

%% What the editor says -- a field being written and its choices, a
%% message -- over the canvas; hidden when it says nothing.
edit_status(_H, #{ed_status := T, tabs_panel := P}, Text) ->
    %% `&' in a label is the key it is reached by; the editor's `& series'
    %% means an ampersand.
    wxStaticText:setLabel(T, lists:flatten(string:replace(Text, "&", "&&", all))),
    wxWindow:show(T, [{show, Text =/= ""}]),          % nothing said, no room taken
    candid_wx:relayout_up(P).

%% Rows Y0..Y1 of the picture (its own pixels) scrolled into sight, with a
%% row to spare: the cursor's node after a key moved it.
see(H, #{canvas := C, right := Right}, Y0, Y1) ->
    Z = zoom(H),
    {_, Oy} = in_right(C),
    {_, Uy} = wxScrolledWindow:getScrollPixelsPerUnit(Right),
    {_, Vy} = wxScrolledWindow:getViewStart(Right),
    {_, Rh} = wxWindow:getClientSize(Right),
    Top = Vy * Uy,
    A = Top + Oy + round(Y0 * Z) - 30,
    B = Top + Oy + round(Y1 * Z) + 30,
    New = if A < Top -> A;
             B > Top + Rh -> B - Rh;
             true -> Top
          end,
    (New =/= Top andalso Uy > 0) andalso
        wxScrolledWindow:scroll(Right, -1, max(0, New div Uy)),
    ok.

%% The whole picture again.
draw(H, #{canvas := C}, Ops) ->
    store(H, Ops),
    wxWindow:refresh(C, [{eraseBackground, false}]).

%% A pen and a brush per colour and style, made once a paint; a pen, a
%% brush, a font and a text colour set on the DC only when the op wants
%% another than is set -- one wx call less, most ops: neighbours are alike.
paint_ops(H, DC, {Bx, By, Bw, Bh}) ->
    Bg = wxBrush:new(candid_wx:tc(H, ?BG)),
    wxDC:setBackground(DC, Bg),
    wxDC:clear(DC),
    wxBrush:destroy(Bg),
    Z = zoom(H),
    %% the box in the picture's own pixels, a row's height to spare
    {X0, Y0, X1, Y1} = {Bx / Z - 40, By / Z - 40, (Bx + Bw) / Z + 40, (By + Bh) / Z + 40},
    In = fun({rect, X, Y, W, Ht, _, _, _, _}) -> Y < Y1 andalso Y + Ht > Y0 andalso
                                                  X < X1 andalso X + W > X0;
            ({line, Xa, Ya, Xb, Yb, _, _, _}) -> min(Ya, Yb) < Y1 andalso max(Ya, Yb) > Y0
                                                  andalso min(Xa, Xb) < X1 andalso
                                                  max(Xa, Xb) > X0;
            ({text, _X, Y, _, _, _}) -> Y < Y1 andalso Y + 40 > Y0
         end,
    Ops = [Op || Op <- ops(H, Y0, Y1), In(Op)],
    wxDC:setUserScale(DC, Z, Z),
    Font = candid_wx:font(H),
    Bold = wxFont:new(wxFont:getPointSize(Font), ?wxFONTFAMILY_TELETYPE,
		      ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    wxDC:setFont(DC, Font),
    Tools = lists:foldl(fun(Op, T) -> op(H, DC, Op, T, Font, Bold) end, #{font => false}, Ops),
    [case K of
	 {pen, _, _, _} -> wxPen:destroy(X);
	 {brush, _}     -> wxBrush:destroy(X);
	 _              -> ok
     end || {K, X} <- maps:to_list(Tools)],
    wxFont:destroy(Bold),
    ok.

op(H, DC, {rect, X, Y, W, Ht, R, F, S, D}, T0, _F, _B) ->
    T1 = set(T0, brush, F, fun() -> {Br, T} = brush(H, F, T0), wxDC:setBrush(DC, Br), T end),
    T2 = set(T1, pen, {S, 1, D}, fun() -> {P, T} = pen(H, S, 1, D, T1), wxDC:setPen(DC, P), T end),
    wxDC:drawRoundedRectangle(DC, {X, Y, W, Ht}, R),
    T2;
op(H, DC, {line, X1, Y1, X2, Y2, C, W, D}, T0, _F, _B) ->
    T1 = set(T0, pen, {C, W, D}, fun() -> {P, T} = pen(H, C, W, D, T0), wxDC:setPen(DC, P), T end),
    wxDC:drawLine(DC, {X1, Y1}, {X2, Y2}),
    T1;
op(H, DC, {text, X, Y, Txt, C, Bold}, T0, Font, BoldF) ->
    T1 = set(T0, font, Bold, fun() -> wxDC:setFont(DC, case Bold of true -> BoldF; false -> Font end),
				      T0 end),
    T2 = set(T1, fg, C, fun() -> wxDC:setTextForeground(DC, candid_wx:tc(H, C, fg)), T1 end),
    wxDC:drawText(DC, Txt, {X, Y}),
    T2.

%% What is set on the DC as What is V: Set() sets it when it is not.
set(T, What, V, Set) ->
    case T of
        #{What := V} -> T;
        _ -> (Set())#{What => V}
    end.

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
c(K, #{colours := C}) -> candid_wx:colour(maps:get(K, C)).
fill(K, Hd) -> candid_wx:mix(c(K, Hd), 25, {17, 17, 17}).
ink(K, Hd)  -> candid_wx:mix(c(K, Hd), 35, {255, 255, 255}).

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

%%% candid's renderer for the desktop, through wx: the same panel candid_wse
%%% puts in a browser, in a window of its own -- for an AppImage, Windows and
%%% macOS, where a friend can try candyspeak without a web server.
%%%
%%% candid (the core) decides what there is and what it shows; this draws it
%%% and reads the window's events back into what the core reads (event/2).
%%% Every function takes the handle first, H = #{env, frame, ids, font}.
%%%
%%% `ids' is an ets table, the window's getElementById: the code view names
%%% its pieces (k<N>_<I>, sl_<N>, tr_<C>_<I> ...) and paints them by name, and
%%% some of them -- a device's label, the State box -- are made here. The
%%% process that runs the panel owns it.
%%%
%%% EVENTS. A command (a click, a choice, Enter in a field) comes to the
%%% panel's process as #wx{userData = What}; what must be decided while the
%%% window holds the event -- a button held and let go, a drag on a plot --
%%% is a callback that sends {candid_wx, Event}. event/2 reads both.
%%%
%%% DRAWING. The trace and the plots are bitmaps, drawn in candid.hrl's
%%% pixels and shown by a paint callback; the plot's afterglow decays per
%%% pixel, as candid_wse's does (see its plotter/1 for why not a wash).

-module(candid_wx).

-include_lib("wx/include/wx.hrl").
-include("candid.hrl").

-export([start/0, start/1, start0/0, code_view/0, chat_view/0, log_view/0]).
-export([clear/2, message/3, chooser/3, panel/3, event/2, open_file/2,
	 save_file/4, tabs/3]).
-export([status/3, trace_view/3, theme/2, view_buttons/4, mode/3]).
-export([tc/3, is_light/1, theme_hook/3]).
-export([rich/3, rich_add/4, rich_trim/3, rich_clear/2]).
-export([btn/4, btn_on/3, btn_enable/3, btn_label/3, btn_group/3, menu_btn/5]).
-export([paint/3, trace_clear/2, trace_column/3, plot/4]).
-export([fg/3, bg/3, tc/2]).
-export([colour/1, mix/3, font/1, label/2, relayout_up/1, canvas/4, redraw/3, register/3, register/4,
	 forget/2, lookup/2, click/3, frame_box/2, text/4]).
-export([dock_pane/4, dock_show/3, in_scope/3, lookup_scope/2]).                % the log's and the chat's                          % csp_code_wx's

-define(BG,      {18, 18, 18}).
-define(INK,     {221, 221, 221}).
-define(DIM,     {136, 136, 136}).
-define(LABEL_W, 110).
-define(PIXEL,   22).
-define(DOCK_H,  300).

%%% ------------------------------------------------------------ starting

%% What a packaged candid takes along besides what runs at once: varp for
%% the proofs, ellm and what it talks through for the chat, wse for the
%% browser panel.
-define(BUNDLE, [candid, csp_tools, varp, wx, ellm, rester, wse, uart,
		 inets, ssl, crypto, public_key, asn1]).

%% A window of its own, and the panel's loop in the process that made it.
start() -> start(default).

%% servator's `prepare, do not start': `-s candid_wx start0' when packaging
%% is `-s candid_wx start' in the package. servator copies what is LOADED,
%% so everything the package needs is loaded here.
start0() ->
    [application:load(A) || A <- ?BUNDLE],
    ok.

start(File) ->
    _ = application:load(candid),
    spawn(fun() ->
		  Wx = wx:new(),
		  F = wxFrame:new(Wx, ?wxID_ANY, "candid", [{size, {1400, 900}}]),
		  ok = wxFrame:connect(F, close_window),
		  %% The dock: the log's and the chat's panes, under the panel
		  %% and outside what a rebuild tears down.
		  Dock = wxPanel:new(F, [{size, {-1, ?DOCK_H}}]),
		  wxWindow:setSizer(Dock, wxBoxSizer:new(?wxHORIZONTAL)),
		  wxWindow:hide(Dock),
		  H = #{env => wx:get_env(), frame => F, dock => Dock,
			ids => ets:new(candid_wx, [set, public]),
			font => wxFont:new(10, ?wxFONTFAMILY_TELETYPE,
					   ?wxFONTSTYLE_NORMAL,
					   ?wxFONTWEIGHT_NORMAL)},
		  bg(H, Dock, ?BG),
		  wxFrame:show(F),
		  case File of
		      default -> candid:run_ui({?MODULE, H}, F);
		      _       -> candid:run_ui({?MODULE, H}, F, File)
		  end,
		  wx:destroy()
	  end).

%% Who draws the code view, the chat and the log here.
code_view() -> csp_code_wx.
chat_view() -> csp_chat_wx.
log_view() -> candid_log_wx.

%%% ------------------------------------------------------------ the page

%% The window emptied for a rebuild, and a fresh root to build in. The dock
%% stays.
clear(H = #{ids := Ids, dock := Dock}, Frame) ->
    Keep = [E || E = {K, _, _} <- ets:tab2list(Ids), outlives(K, Dock)],
    ets:delete_all_objects(Ids),
    ets:insert(Ids, Keep),
    Fs = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Frame, Fs),
    [wxWindow:destroy(W) || W <- wxWindow:getChildren(Frame),
			    wxWindow:getId(W) =/= wxWindow:getId(Dock)],
    Root = wxPanel:new(Frame),
    bg(H, Root, ?BG),
    fg(H, Root, ?INK),
    wxWindow:setSizer(Root, wxBoxSizer:new(?wxVERTICAL)),
    wxSizer:add(Fs, Root, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxSizer:add(Fs, Dock, [{flag, ?wxEXPAND}]),
    register(H, theme_root, Root),
    Root.

%% What a rebuild leaves: the theme, and what the dock's panes coloured.
outlives(theme, _Dock) -> true;
outlives({rich, _}, _Dock) -> true;
outlives({theme_hook, _}, _Dock) -> true;
outlives({btn, W}, Dock) -> within(W, Dock);
outlives({colour, W, _}, Dock) -> within(W, Dock);
outlives(_, _Dock) -> false.

within(W, Dock) ->
    case wx:is_null(W) of
	true -> false;
	false ->
	    element(2, W) =:= element(2, Dock) orelse
		within(wxWindow:getParent(W), Dock)
    end.

%%% ------------------------------------------------------------ the dock
%%%
%%% The log on the left, the chat on the right, each with its title and a
%%% close; the dock is shown while either is. Each pane is made by its own
%%% process, whose callbacks send it Close.

%% A pane in the dock, hidden: {Pane, Sizer} to fill.
dock_pane(H = #{dock := Dock}, Title, Where, Close) ->
    P = wxPanel:new(Dock),
    bg(H, P, ?BG),
    S = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(P, S),
    Head = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Head, text(H, P, Title, {153, 204, 255}),
		[{proportion, 1}, {flag, ?wxALIGN_CENTER_VERTICAL bor ?wxLEFT},
		 {border, 4}]),
    Pid = self(),
    X = btn(H, P, "close", #{click => fun() -> Pid ! Close end}),
    wxSizer:add(Head, X),
    wxSizer:add(S, Head, [{flag, ?wxEXPAND bor ?wxALL}, {border, 2}]),
    Opts = [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 2}],
    case Where of
	left  -> wxSizer:insert(wxWindow:getSizer(Dock), 0, P, Opts);
	right -> wxSizer:add(wxWindow:getSizer(Dock), P, Opts)
    end,
    wxWindow:hide(P),
    {P, S}.

dock_show(#{dock := Dock, frame := F}, P, On) ->
    wxWindow:show(P, [{show, On}]),
    wxWindow:show(Dock, [{show, lists:any(fun wxWindow:isShown/1,
					   wxWindow:getChildren(Dock))}]),
    wxWindow:layout(Dock),
    wxWindow:layout(F),
    ok.

message(H, Root, Str) ->
    T = text(H, Root, lists:flatten(Str), {238, 119, 119}),
    wxSizer:add(wxWindow:getSizer(Root), T, [{flag, ?wxALL}, {border, 8}]),
    relayout(Root).

%% The bar: the chooser, the target, run/pause/step, the tick, the views and
%% the chat. Back: the chooser's event (any term; the bar's events say what
%% they are) and the bar's buttons, as candid_wse gives them.
chooser(H, Root, Spec = #{target := Target,
			  period := Now, periods := Periods, views := Views,
			  chat := Chat}) ->
    %% The tabs, then two rows: what runs and how, then what is shown.
    Bar = wxBoxSizer:new(?wxVERTICAL),
    Row0 = wxBoxSizer:new(?wxHORIZONTAL),
    Row1 = wxBoxSizer:new(?wxHORIZONTAL),
    Row2 = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Bar, Row0, [{flag, ?wxBOTTOM}, {border, 4}]),
    wxSizer:add(Bar, Row1, []),
    wxSizer:add(Bar, Row2, []),
    Pid = self(),
    tabs(H, Root, Row0, maps:get(tabs, Spec, []), Pid),
    In = fun(Row) -> fun(W) -> wxSizer:add(Row, W, [{flag, ?wxALL bor
						     ?wxALIGN_CENTER_VERTICAL},
						    {border, 3}]), W end end,
    %% The buttons that go together in a frame of their own, named on it:
    %% run, and each view. The buttons side by side, no gap.
    Group = fun(Row, Title) ->
		    {G, Gs} = btn_group(H, Root, Title),
		    wxSizer:add(Row, G, [{flag, ?wxLEFT bor ?wxRIGHT bor
					  ?wxALIGN_CENTER_VERTICAL},
					 {border, 3}]),
		    {G, fun(W) -> wxSizer:add(Gs, W, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
				  W end}
	    end,
    Button = fun({G, In1}, Label, Tag) ->
		     In1(btn(H, G, Label,
			     #{click => fun() -> Pid ! {candid_wx, {bar, Tag}} end}))
	     end,
    File = Group(Row1, "file"),
    Button(File, "open\x{2026}", "open"),
    Button(File, "new", "new"),
    Button(File, "save", "save"),
    Button(File, "save as\x{2026}", "saveas"),
    Add = In(Row1),
    Tgt = Add(wxTextCtrl:new(Root, ?wxID_ANY,
			     [{value, Target}, {size, {260, -1}},
			      {style, ?wxTE_PROCESS_ENTER}])),
    bg(H, Tgt, {34, 34, 34}),
    fg(H, Tgt, ?INK),
    wxWindow:setFont(Tgt, font(H)),
    wxWindow:setToolTip(Tgt, "local, or a can interface: a csp of our own on "
			"that bus\nhost:port or /dev/tty...[@baud]: a node's "
			"console\nrom | eeprom: without or with the EEPROM patch\n"
			"image=SLOT: read a node's program from that flash slot"),
    wxTextCtrl:connect(Tgt, command_text_enter, [{userData, {bar_text, "target="}}]),
    Run = {RBox, RIn} = Group(Row1, "run"),
    RunB = Button(Run, "go", "mode=run"),
    PauseB = Button(Run, "pause", "mode=step"),
    OneB = Button(Run, "step", "step=1"),
    RIn(text(H, RBox, "  tick ", ?DIM)),
    Ps = lists:usort([Now | Periods]),
    RIn(menu_btn(H, RBox, [integer_to_list(P) ++ " ms" || P <- Ps],
		 index_of(Now, Ps),
		 fun(I) -> Pid ! {candid_wx, {bar, "period=" ++
					      integer_to_list(lists:nth(I, Ps))}}
		 end)),
    Vs = lists:append(
	   [begin
		G = Group(Row2, K),
		[{{K, V}, Button(G, V, K ++ "=" ++ V)} || V <- Vals]
	    end || {K, Vals} <- Views]),
    Panes = Group(Row2, "panes"),
    Chat andalso Button(Panes, "chat", "chat=toggle"),
    Button(Panes, "log", "log=toggle"),
    wxSizer:add(wxWindow:getSizer(Root), Bar, [{flag, ?wxALL bor ?wxEXPAND},
					       {border, 4}]),
    relayout(Root),
    {pick, #{event => bar, run => RunB, pause => PauseB, one => OneB,
	     views => maps:from_list(Vs), tabs => {Root, Row0, Pid}}}.

%% The tabs again, as they are now: a file saved under another name.
tabs(H, #{tabs := {Root, Row, Pid}}, Tabs) ->
    wxSizer:clear(Row, [{delete_windows, true}]),
    tabs(H, Root, Row, Tabs, Pid),
    relayout(Root).

%% A tab per file open: its name, lit when it is the one shown, a node's
%% marked live, and a cross to close it.
tabs(H, Root, Row, Tabs, Pid) ->
    Send = fun(Tag) -> fun() -> Pid ! {candid_wx, {bar, Tag}} end end,
    [begin
	 Id = integer_to_list(I),
	 Label = case Live of
		     true  -> "\x{25CF} " ++ L;
		     false -> L
		 end,
	 B = btn(H, Root, Label, #{click => Send("tab=" ++ Id)}),
	 Active andalso btn_on(H, B, true),
	 Live andalso wxWindow:setToolTip(B, "live: a node's program, patch "
					  "mode -- rules added and turned "
					  "off, nothing else"),
	 X = btn(H, Root, "\x{00D7}", #{click => Send("close=" ++ Id)}),
	 wxSizer:add(Row, B, []),
	 wxSizer:add(Row, X, [{flag, ?wxRIGHT}, {border, 6}])
     end || #{id := I, label := L, live := Live, active := Active} <- Tabs],
    ok.

%% The desktop's own file dialog: {ok, Path} or cancel.
open_file(#{frame := F}, Dir) ->
    D = wxFileDialog:new(F, [{message, "open a program"}, {defaultDir, Dir},
			     {wildCard, "CandySpeak (*.csp)|*.csp|all files|*"},
			     {style, ?wxFD_OPEN bor ?wxFD_FILE_MUST_EXIST}]),
    R = case wxFileDialog:showModal(D) of
	    ?wxID_OK -> {ok, wxFileDialog:getPath(D)};
	    _ -> cancel
	end,
    wxFileDialog:destroy(D),
    R.

%% The same for saving, Name offered: {ok, Path} or cancel.
save_file(#{frame := F}, _Bar, Dir, Name) ->
    D = wxFileDialog:new(F, [{message, "save the program as"},
			     {defaultDir, Dir}, {defaultFile, Name},
			     {wildCard, "CandySpeak (*.csp)|*.csp|all files|*"},
			     {style, ?wxFD_SAVE bor ?wxFD_OVERWRITE_PROMPT}]),
    R = case wxFileDialog:showModal(D) of
	    ?wxID_OK -> {ok, wxFileDialog:getPath(D)};
	    _ -> cancel
	end,
    wxFileDialog:destroy(D),
    R.

index_of(X, L) -> index_of(X, L, 0).
index_of(X, [X | _], I) -> I;
index_of(X, [_ | T], I) -> index_of(X, T, I + 1);
index_of(_, [], _) -> 0.

%% The page under the bar, as candid_wse:panel/3 makes it: the top frame
%% (State, clock, link, and room for the code view's goal and answer), the
%% devices left and the code view right, the trace at the bottom.
panel(H, Root, #{rows := Rows, pixels := Pixels, plots := Plots0,
		 traces := Traces}) ->
    RS = wxWindow:getSizer(Root),
    Top = wxPanel:new(Root),
    TopS = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(Top, TopS),
    Status = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(TopS, Status, [{flag, ?wxALL}, {border, 2}]),
    Box = fun(Id) ->
		  B = text(H, Top, " ", ?INK),
		  wxWindow:setMinSize(B, {140, -1}),
		  wxSizer:add(Status, B, [{flag, ?wxALL bor ?wxALIGN_CENTER_VERTICAL},
					  {border, 4}]),
		  register(H, Id, {text, B}),
		  B
	  end,
    StateBox = Box("csp_st"),
    Clock = Box("csp_clock"),
    LinkBox = Box("csp_link"),
    wxSizer:add(RS, Top, [{flag, ?wxEXPAND bor ?wxALL}, {border, 2}]),
    Main = wxBoxSizer:new(?wxHORIZONTAL),
    Left = scrolled(Root),
    Right = scrolled(Root),
    wxWindow:setMinSize(Left, {420, -1}),
    wxSizer:add(Main, Left, [{flag, ?wxEXPAND}]),
    wxSizer:add(Main, Right, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxLEFT},
			      {border, 24}]),
    wxSizer:add(RS, Main, [{proportion, 1}, {flag, ?wxEXPAND}]),
    TraceBox = wxScrolledWindow:new(Root),
    wxScrolledWindow:setScrollRate(TraceBox, 5, 5),
    wxWindow:setSizer(TraceBox, wxBoxSizer:new(?wxVERTICAL)),
    wxWindow:setMinSize(TraceBox, {-1, 260}),
    wxSizer:add(RS, TraceBox, [{flag, ?wxEXPAND bor ?wxTOP}, {border, 8}]),
    wxWindow:hide(TraceBox),
    RowNodes = lists:append([row_nodes(H, Left, R) || R <- Rows]),
    PixNodes = strip(H, Left, Pixels),
    {Plots, PlotNodes} = plot_panels(H, Left, Plots0),
    Trace = trace_canvas(H, TraceBox, Traces),
    %% As wide as what is in it: a plot's channels sit beside the picture.
    {LW, _} = wxSizer:getMinSize(wxWindow:getSizer(Left)),
    wxWindow:setMinSize(Left, {max(420, LW + 30), -1}),
    wxScrolledWindow:fitInside(Left),
    relayout(Root),
    #{nodes => maps:from_list(RowNodes ++ PixNodes ++ PlotNodes),
      plots => Plots, trace => Trace, trace_box => TraceBox,
      state_box => StateBox, clock_box => Clock, link_box => LinkBox,
      code => #{code => Right, status => {Top, Status}, top => {Top, TopS}}}.

scrolled(Parent) ->
    W = wxScrolledWindow:new(Parent),
    wxScrolledWindow:setScrollRate(W, 5, 5),
    wxWindow:setSizer(W, wxBoxSizer:new(?wxVERTICAL)),
    W.

%% What the window said, as the core reads it.
event(_Ids, #wx{userData = {bar_text, Pre}, event = #wxCommand{cmdString = S}}) ->
    {bar, Pre ++ S};
event(_Ids, #wx{userData = {bar, Tag}})    -> {bar, Tag};
event(_Ids, #wx{userData = {code, Tag}})   -> {code, Tag};
event(_Ids, #wx{userData = {widget, D}})   -> {widget, D};
event(_Ids, #wx{userData = {slider, N}, event = #wxCommand{commandInt = V}}) ->
    {widget, N ++ "=" ++ integer_to_list(V)};
event(_Ids, #wx{userData = {invalue, N}, event = #wxCommand{cmdString = S}}) ->
    {widget, N ++ "=" ++ string:trim(S)};
event(_Ids, #wx{event = #wxClose{}})       -> closed;
event(_Ids, {candid_wx, Ev})               -> Ev;
event(_Ids, _Msg)                          -> none.

%%% ------------------------------------------------------------ what changes

status(_H, B, Text) ->
    label(B, Text),
    wxWindow:invalidateBestSize(B),
    wxWindow:setMinSize(B, wxWindow:getBestSize(B)),
    wxWindow:layout(wxWindow:getParent(B)).

trace_view(_H, TraceBox, Show) ->
    wxWindow:show(TraceBox, [{show, Show}]),
    relayout(wxWindow:getParent(TraceBox)).

%% DARK is the panel as drawn; LIGHT the page and its frames pale. A widget's
%% own colours -- a lamp, a contact -- stay: they say something.
theme(H = #{ids := Ids}, T) ->
    ets:insert(Ids, {theme, T, perm}),
    [wx_colour(W, Which, tc(H, C, Which))
     || {{colour, W, Which}, C, _} <- ets:tab2list(Ids)],
    [Fun(T) || {{theme_hook, _}, Fun, _} <- ets:tab2list(Ids)],
    [wxWindow:refresh(W) || {theme_root, W, _} <- ets:lookup(Ids, theme_root)],
    wxWindow:refresh(maps:get(dock, H)),
    ok.

view_buttons(H, #{views := Views}, Key, V) ->
    [btn_on(H, B, Val =:= V)
     || {{K1, Val}, B} <- maps:to_list(Views), K1 =:= Key],
    ok.

mode(H, #{run := RunB, pause := PauseB, one := OneB}, Step) ->
    btn_on(H, RunB, not Step),
    btn_on(H, PauseB, Step),
    %% the step button is only live while stopped
    btn_enable(H, OneB, Step).

paint(H, Node, V) ->
    paint1(H, Node, V).

%% The trace wraps: clear right of the labels.
trace_clear(_H, {P, Bmp}) ->
    redraw(P, Bmp, fun(DC) -> rect(DC, {?GUTTER, 0, ?TRACE_W, 4096}, {26, 26, 26})
		   end).

%% One column: x, y, colour, x, y, colour ...
trace_column(_H, {P, Bmp}, Items) ->
    redraw(P, Bmp, fun(DC) -> column(DC, Items) end).

%% A brush per colour, not per item: a column is every signal, every tick.
column(DC, Items) ->
    wxDC:setPen(DC, ?wxTRANSPARENT_PEN),
    [begin
	 Br = wxBrush:new(colour(C)),
	 wxDC:setBrush(DC, Br),
	 [wxDC:drawRectangle(DC, {X, Y, ?STEP, 3}) || {X, Y} <- XYs],
	 wxBrush:destroy(Br)
     end || {C, XYs} <- maps:to_list(by_colour(Items, #{}))],
    ok.

by_colour([X, Y, C | T], M) ->
    by_colour(T, maps:update_with(C, fun(L) -> [{X, Y} | L] end, [{X, Y}], M));
by_colour([], M) -> M.

%% One frame of a plot: everything already drawn decays toward the glass by
%% Keep, then the graticule, then per channel the segment and its dot.
plot(_H, #{ctx := {P, Bmp}, round := Rnd, beam := Beam, dot := Dot,
	   step := Step}, Keep, Items) ->
    decay(Bmp, Keep),
    redraw(P, Bmp, fun(DC) ->
			   graticule(DC, Rnd),
			   beams(DC, Items, Beam, Dot, Step)
		   end).

%% Per pixel, the distance to the background multiplied and TRUNCATED, so a
%% trail always reaches the glass -- see candid_wse:plotter/1.
decay(Bmp, Keep) ->
    Img = wxBitmap:convertToImage(Bmp),
    Data = wxImage:getData(Img),
    {Br, Bgc, Bb} = ?PLOT_BG,
    L = list_to_tuple([trunc(J * Keep) || J <- lists:seq(0, 255)]),
    F = fun(V, B) when V >= B -> B + element(V - B + 1, L);
	   (V, B) -> B - element(B - V + 1, L)
	end,
    New = << <<(F(R, Br)), (F(G, Bgc)), (F(B, Bb))>> || <<R, G, B>> <= Data >>,
    W = wxBitmap:getWidth(Bmp),
    H = wxBitmap:getHeight(Bmp),
    Img2 = wxImage:new(W, H, New),
    B2 = wxBitmap:new(Img2),
    DC = wxMemoryDC:new(Bmp),
    wxDC:drawBitmap(DC, B2, {0, 0}),
    wxMemoryDC:destroy(DC),
    wxBitmap:destroy(B2),
    wxImage:destroy(Img2),
    wxImage:destroy(Img).

graticule(DC, Round) ->
    Pen = wxPen:new({32, 52, 32}, [{width, 1}]),
    wxDC:setPen(DC, Pen),
    wxDC:setBrush(DC, ?wxTRANSPARENT_BRUSH),
    W = ?PLOT_W,
    case Round of
	true ->
	    C = W div 2, R = W div 2 - 2,
	    [wxDC:drawCircle(DC, {C, C}, R * G div 3) || G <- [1, 2, 3]],
	    wxDC:drawLine(DC, {C - R, C}, {C + R, C}),
	    wxDC:drawLine(DC, {C, C - R}, {C, C + R});
	false ->
	    [begin
		 Q = K * W div 4,
		 wxDC:drawLine(DC, {Q, 0}, {Q, W}),
		 wxDC:drawLine(DC, {0, Q}, {W, Q})
	     end || K <- [1, 2, 3]]
    end,
    wxPen:destroy(Pen).

beams(DC, [X0, Y0, X1, Y1, C | T], Beam, Dot, Step) ->
    Col = colour(C),
    Pen = wxPen:new(Col, [{width, max(1, round(Beam))}]),
    wxDC:setPen(DC, Pen),
    if X0 >= 0, Beam > 0 ->
	    case Step of
		true ->
		    wxDC:drawLine(DC, {X0, Y0}, {X1, Y0}),
		    wxDC:drawLine(DC, {X1, Y0}, {X1, Y1});
		false ->
		    wxDC:drawLine(DC, {X0, Y0}, {X1, Y1})
	    end;
       true -> ok
    end,
    if Dot > 0 ->
	    Br = wxBrush:new(Col),
	    wxDC:setBrush(DC, Br),
	    wxDC:drawCircle(DC, {X1, Y1}, max(1, round(Dot))),
	    wxBrush:destroy(Br);
       true -> ok
    end,
    wxPen:destroy(Pen),
    beams(DC, T, Beam, Dot, Step);
beams(_DC, [], _Beam, _Dot, _Step) -> ok.

%%% ------------------------------------------------------------ building

%% A row per widget: the label -- a signal to mark for the code view, by
%% click -- then the control.
row(H, Left, {Kind, Name, _W}, Look) ->
    LS = wxWindow:getSizer(Left),
    Row = wxBoxSizer:new(?wxHORIZONTAL),
    {Frame, Label} = frame_box(Left, maps:get(label, Look)),
    wxWindow:setMinSize(Frame, {?LABEL_W, -1}),
    wxWindow:setFont(Label, font(H)),
    fg(H, Label, {204, 204, 204}),
    click(Label, {code, "sig=" ++ Name}, self()),
    register(H, "sl_" ++ Name, {frame, Frame}),
    wxSizer:add(Row, Frame, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    Node = case Kind of
	       toggle  -> switch(H, Left, Row, Name, Look);
	       push    -> push(H, Left, Row, Name, Look);
	       lamp    -> lamp(H, Left, Row, Look);
	       action  -> action(H, Left, Row, Look);
	       slider  -> slider(H, Left, Row, Name, Look);
	       dial    -> dial(H, Left, Row, Name, Look);
	       invalue -> invalue(H, Left, Row, Name, Look);
	       meter   -> meter(H, Left, Row, Look);
	       value   -> value_out(H, Left, Row, Look)
	   end,
    wxSizer:add(LS, Row, [{flag, ?wxALL}, {border, 4}]),
    Node.

row_nodes(H, Left, {keypad, Pad}) -> keypad(H, Left, Pad);
row_nodes(H, Left, {group, G}) -> group(H, Left, G);
row_nodes(H, Left, {W = {_, Name, _}, Look}) -> [{Name, row(H, Left, W, Look)}].

%% A group with no kind of its own: its name, and under it the members'
%% rows as they would be anyway.
group(H, Left, #{label := Label, rows := Rows}) ->
    T = text(H, Left, Label, {136, 170, 187}),
    wxSizer:add(wxWindow:getSizer(Left), T, [{flag, ?wxTOP bor ?wxLEFT}, {border, 6}]),
    [{Name, row(H, Left, W, Look)} || {W = {_, Name, _}, Look} <- Rows].

%% A keypad: its label, then the keys in a grid of `cols' columns, each a
%% push or a toggle as it is declared, named by its label, lit while away
%% from rest.
keypad(H, Left, #{label := Label, cols := Cols, keys := Keys}) ->
    Row = wxBoxSizer:new(?wxHORIZONTAL),
    L = text(H, Left, Label, {204, 204, 204}),
    wxWindow:setMinSize(L, {?LABEL_W, -1}),
    wxSizer:add(Row, L, []),
    Grid = wxGridSizer:new(0, Cols, 4, 4),
    Nodes = [begin
		 {switch, B, Hue, Idle} = case Kind of
					      push   -> push(H, Left, Grid, Name, Look);
					      toggle -> switch(H, Left, Grid, Name, Look)
					  end,
		 btn_label(H, B, maps:get(label, Look)),
		 {Name, {key, B, Hue, Idle}}
	     end || {{Kind, Name, _}, Look} <- Keys],
    wxSizer:add(Row, Grid, []),
    wxSizer:add(wxWindow:getSizer(Left), Row, [{flag, ?wxALL}, {border, 4}]),
    Nodes.

%% A label in a frame of its own, the frame's colour being the mark: wx has
%% no outline, so the mark is the panel round the text.
frame_box(Parent, Label) ->
    F = wxPanel:new(Parent),
    S = wxBoxSizer:new(?wxHORIZONTAL),
    wxWindow:setSizer(F, S),
    T = wxStaticText:new(F, ?wxID_ANY, ""),
    label(T, Label),
    wxSizer:add(S, T, [{flag, ?wxALL}, {border, 2}]),
    {F, T}.

%% A click on W sends Ev to Pid, the panel's process.
click(W, Ev, Pid) ->
    wxWindow:connect(W, left_down,
		     [{callback, fun(_E, O) -> Pid ! {candid_wx, Ev},
					       wxEvent:skip(O) end}]).

switch(H, Left, Row, Name, Look = #{colour := Hue}) ->
    Idle = maps:get(idle, Look, 0),
    Pid = self(),
    B = btn(H, Left, integer_to_list(Idle),
	    #{min_w => 60,
	      click => fun() -> Pid ! {candid_wx, {widget, Name}} end}),
    wxSizer:add(Row, B, []),
    {switch, B, Hue, Idle}.

%% Held down rather than latched: the pressed level while held, the resting
%% one on release -- 1 and 0, or 0 and 1 for a button to ground.
push(H, Left, Row, Name, Look = #{colour := Hue}) ->
    Idle = maps:get(idle, Look, 0),
    Pid = self(),
    Send = fun(V) -> fun() -> Pid ! {candid_wx, {widget, Name ++ "=" ++
					     integer_to_list(V)}}
		     end
	   end,
    %% dragging off must not leave it held: btn lets go on leaving
    B = btn(H, Left, integer_to_list(Idle),
	    #{min_w => 60, down => Send(1 - Idle), up => Send(Idle)}),
    wxSizer:add(Row, B, []),
    {switch, B, Hue, Idle}.

lamp(H, Left, Row, #{colour := {_On, Off} = Hue}) ->
    L = wxPanel:new(Left, [{size, {18, 18}}]),
    bg(H, L, colour(Off)),
    wxSizer:add(Row, L, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    {lamp, L, Hue}.

action(H, Left, Row, #{colour := Hue}) ->
    T = wxStaticText:new(Left, ?wxID_ANY, "  off  "),
    wxWindow:setFont(T, font(H)),
    action_style(H, T, 0, Hue),
    wxSizer:add(Row, T, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    {action, T, Hue}.

action_style(H, T, V, {On, Off}) ->
    case V of
	0 -> bg(H, T, colour(Off)),
	     fg(H, T, {119, 119, 119});
	_ -> bg(H, T, colour(On)),
	     fg(H, T, {17, 17, 17})
    end,
    wxWindow:refresh(T).

%% The range is the look's min..max, as candid_wse's: a signed channel goes
%% below zero, and a narrowed one gives the whole travel to what matters.
slider(H, Left, Row, Name, Look = #{min := Min, max := Max}) ->
    S = wxSlider:new(Left, ?wxID_ANY, trunc(min(max(0, Min), Max)),
		     trunc(Min), trunc(Max), [{size, {200, -1}}]),
    wxSlider:connect(S, command_slider_updated, [{userData, {slider, Name}}]),
    wxSizer:add(Row, S, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    Out = readout(H, Left, Row),
    {slider, S, Out, Look}.

%% A slider for the hand and a needle for the eye.
dial(H, Left, Row, Name, Look) ->
    Face = canvas(Left, 38, 38, {37, 37, 37}),
    wxSizer:add(Row, element(1, Face), [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxRIGHT},
					{border, 8}]),
    needle(Face, maps:get(min, Look), Look),
    {slider, S, Out, Look} = slider(H, Left, Row, Name, Look),
    {dial, Face, S, Out, Look}.

%% -135..+135 degrees over min..max, the usual instrument sweep.
needle({P, Bmp}, V, Look = #{colour := {On, _}}) ->
    A = (-135 + 270 * candid:frac(V, Look)) * math:pi() / 180,
    redraw(P, Bmp, fun(DC) ->
			   rect(DC, {0, 0, 38, 38}, {37, 37, 37}),
			   Pen = wxPen:new(colour(On), [{width, 2}]),
			   wxDC:setPen(DC, Pen),
			   wxDC:drawLine(DC, {19, 19}, {19 + round(15 * math:sin(A)),
							19 - round(15 * math:cos(A))}),
			   wxPen:destroy(Pen)
		   end).

invalue(H, Left, Row, Name, #{colour := {On, _}}) ->
    I = wxTextCtrl:new(Left, ?wxID_ANY, [{size, {90, -1}},
					 {style, ?wxTE_PROCESS_ENTER}]),
    wxWindow:setFont(I, font(H)),
    fg(H, I, colour(On)),
    %% on Enter, not on every keystroke: half a number is not a value
    wxTextCtrl:connect(I, command_text_enter, [{userData, {invalue, Name}}]),
    wxSizer:add(Row, I, []),
    {invalue, I}.

value_out(H, Left, Row, Look = #{colour := {On, _}}) ->
    T = wxStaticText:new(Left, ?wxID_ANY, "0", [{size, {80, -1}}]),
    wxWindow:setFont(T, font(H)),
    fg(H, T, colour(On)),
    wxSizer:add(Row, T, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    {value, T, Look}.

meter(H, Left, Row, Look) ->
    G = wxGauge:new(Left, ?wxID_ANY, 1000, [{size, {200, 12}}]),
    wxSizer:add(Row, G, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    Out = readout(H, Left, Row),
    {meter, G, Out, Look}.

readout(H, Left, Row) ->
    T = wxStaticText:new(Left, ?wxID_ANY, "", [{size, {140, -1}}]),
    wxWindow:setFont(T, font(H)),
    fg(H, T, ?DIM),
    wxSizer:add(Row, T, [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxLEFT},
			 {border, 10}]),
    T.

%% Every port 9 pixel side by side, as the strip is on the board.
strip(_H, _Left, []) -> [];
strip(H, Left, Pixels) ->
    Row = wxBoxSizer:new(?wxHORIZONTAL),
    L = text(H, Left, "port 9", {204, 204, 204}),
    wxWindow:setMinSize(L, {?LABEL_W, -1}),
    wxSizer:add(Row, L, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    Nodes = [begin
		 C = wxPanel:new(Left, [{size, {?PIXEL, ?PIXEL}}]),
		 bg(H, C, {0, 0, 0}),
		 wxWindow:setToolTip(C, maps:get(label, Look)),
		 wxSizer:add(Row, C, [{flag, ?wxRIGHT}, {border, 2}]),
		 {Name, {pixel, C}}
	     end || {Name, Look} <- Pixels],
    wxSizer:add(wxWindow:getSizer(Left), Row, [{flag, ?wxALL}, {border, 6}]),
    Nodes.

%% A canvas per plot group, the channels beside it.
plot_panels(H, Left, Groups) ->
    lists:foldl(fun(G, {Gs, Ns}) ->
			{G1, N1} = plot_panel(H, Left, G),
			{Gs ++ [G1], Ns ++ N1}
		end, {[], []}, Groups).

plot_panel(H, Left, G = #{id := Id, x := X, ys := Ys}) ->
    Row = wxBoxSizer:new(?wxHORIZONTAL),
    L = text(H, Left, Id, {204, 204, 204}),
    wxWindow:setMinSize(L, {?LABEL_W, -1}),
    wxSizer:add(Row, L, []),
    C = {P, _} = canvas(Left, ?PLOT_W, ?PLOT_W, ?PLOT_BG),
    wxSizer:add(Row, P, []),
    Side = wxBoxSizer:new(?wxVERTICAL),
    Members = [{"x", M} || M <- [X], M =/= undefined] ++ [{"y", M} || M <- Ys],
    Nodes = [begin
		 Tag = text(H, Left, Ax ++ "  " ++ maps:get(label, M),
			    colour(maps:get(colour, M))),
		 V = text(H, Left, "", ?DIM),
		 wxWindow:setMinSize(V, {140, -1}),
		 wxSizer:add(Side, Tag, []),
		 wxSizer:add(Side, V, [{flag, ?wxBOTTOM}, {border, 4}]),
		 {maps:get(name, M), {plotval, V, M}}
	     end || {Ax, M} <- Members],
    wxSizer:add(Row, Side, [{flag, ?wxLEFT}, {border, 12}]),
    wxSizer:add(wxWindow:getSizer(Left), Row, [{flag, ?wxALL}, {border, 6}]),
    xy_handler(P, candid:drivable(X, Ys)),
    {G#{ctx => C, plot => wx}, Nodes}.

%%% THE CANVAS IS THE CONTROL: the pointer is the beam. Both axes go as
%%% Name=Value, the wire format a slider uses, together in one event so one
%%% step commits both.
xy_handler(_P, []) -> ok;
xy_handler(P, Sends) ->
    Pid = self(),
    Send = fun(#wxMouse{x = X, y = Y}) ->
		   Pid ! {candid_wx, {widgets, [xy_value(Ax, M, X, Y)
						|| {Ax, M} <- Sends]}}
	   end,
    wxWindow:connect(P, left_down, [{callback, fun(#wx{event = E}, _) -> Send(E) end}]),
    wxWindow:connect(P, motion,
		     [{callback, fun(#wx{event = E = #wxMouse{leftDown = true}}, _) ->
					 Send(E);
				    (_, _) -> ok
				 end}]).

%% The pointer as a fraction of the box over the channel's own min..max; up
%% is UP, as on a scope.
xy_value(Axis, M, X, Y) ->
    Min = maps:get(min, M),
    Max = maps:get(max, M),
    F = case Axis of
	    across -> X / ?PLOT_W;
	    up     -> 1 - Y / ?PLOT_W
	end,
    V = trunc(min(max(Min + round(F * (Max - Min)), Min), Max)),
    maps:get(name, M) ++ "=" ++ integer_to_list(V).

%% The logic trace: one canvas, the names down the left once, in their
%% signals' colours. none with no rows.
trace_canvas(_H, _Box, []) -> none;
trace_canvas(H, Box, Looks) ->
    W = ?GUTTER + ?TRACE_W,
    Ht = length(Looks) * ?ROW_H + 8,
    C = {P, Bmp} = canvas(Box, W, Ht, {26, 26, 26}),
    wxSizer:add(wxWindow:getSizer(Box), P, [{flag, ?wxALL}, {border, 4}]),
    redraw(P, Bmp,
	   fun(DC) ->
		   wxDC:setFont(DC, font(H)),
		   [begin
			wxDC:setTextForeground(DC, colour(element(1, maps:get(colour, L)))),
			wxDC:drawText(DC, short(maps:get(label, L)),
				      {6, I * ?ROW_H + 4 + (?ROW_H - 16) div 2})
		    end || {I, L} <- lists:zip(lists:seq(0, length(Looks) - 1),
						Looks)],
		   rect(DC, {?GUTTER - 4, 0, 1, Ht}, {51, 51, 51})
	   end),
    wxScrolledWindow:fitInside(Box),
    C.

short(S) when length(S) =< 13 -> S;
short(S)                      -> lists:sublist(S, 12) ++ "~".

%%% ------------------------------------------------------------ painting

paint1(H, {ok, {lamp, L, {On, Off}}}, V) ->
    bg(H, L, colour(case V of 0 -> Off; _ -> On end)),
    wxWindow:refresh(L);
%% A switch away from rest shows it in its colour -- a button to ground is
%% pressed at 0.
paint1(H, {ok, {switch, B, {On, _Off}, Idle}}, V) ->
    case V =:= Idle of
	true  -> bg(H, B, {51, 51, 51}),
		 fg(H, B, {238, 238, 238});
	false -> bg(H, B, colour(On)),
		 fg(H, B, {17, 17, 17})
    end,
    btn_label(H, B, case V of 0 -> "0"; _ -> "1" end);
%% A key keeps its name and only lights.
paint1(H, {ok, {key, B, {On, _Off}, Idle}}, V) ->
    case V =:= Idle of
	true  -> bg(H, B, {51, 51, 51}),
		 fg(H, B, {238, 238, 238});
	false -> bg(H, B, colour(On)),
		 fg(H, B, {17, 17, 17})
    end,
    wxWindow:refresh(B);
paint1(_H, {ok, {meter, G, Out, Look}}, V) ->
    wxGauge:setValue(G, trunc(1000 * candid:frac(V, Look))),
    label(Out, lists:flatten(candid:eng(V, Look)));
paint1(H, {ok, {action, T, Hue}}, V) ->
    label(T, case V of 0 -> "  off  "; _ -> "  ON  " end),
    action_style(H, T, V, Hue);
paint1(_H, {ok, {dial, Face, _S, Out, Look}}, V) ->
    needle(Face, V, Look),
    label(Out, lists:flatten(candid:eng(V, Look)));
paint1(_H, {ok, {value, T, Look}}, V) ->
    label(T, lists:flatten(candid:eng(V, Look)));
%% An input's field and a slider are left where the hand put them: csp owning
%% them would fight the hand. Only the readout follows.
paint1(_H, {ok, {invalue, _}}, _V) ->
    ok;
paint1(_H, {ok, {plotval, T, M}}, V) ->
    label(T, lists:flatten(candid:eng(V, M)));
paint1(H, {ok, {pixel, C}}, V) ->
    bg(H, C, colour(candid:rgb565(V))),
    wxWindow:refresh(C);
paint1(_H, {ok, {slider, _S, Out, Look}}, V) ->
    label(Out, lists:flatten(candid:eng(V, Look)));
paint1(_H, _, _V) ->
    ok.

%%% ------------------------------------------------------------ helpers

text(H, Parent, Str, Col) ->
    T = wxStaticText:new(Parent, ?wxID_ANY, ""),
    label(T, Str),
    wxWindow:setFont(T, font(H)),
    fg(H, T, Col),
    T.

font(#{font := F}) -> F.

%%% THE THEME. Every colour goes through fg/3 and bg/3, which keep what was
%%% asked for and show it in the theme in force. LIGHT is what candid_wse
%%% does with a css filter, invert(0.92) hue-rotate(180deg): the lightness
%%% turned over, the hue kept -- so a lamp is still red, and a dark frame is
%%% a pale one. The trace and the plots are screens and stay dark.
fg(H, W, C) -> set_colour(H, W, fg, C).
bg(H, W, C) -> set_colour(H, W, bg, C).

%% A window keeps the scope it was coloured in first; a new one takes the one
%% in force (in_scope/3).
set_colour(#{ids := Ids} = H, W, Which, C0) ->
    C = colour(C0),
    K = {colour, W, Which},
    Scope = case {ets:lookup(Ids, K), ets:lookup(Ids, colour_scope)} of
		{[{_, _, Sc}], _} -> Sc;
		{[], [{_, Sc, _}]} -> Sc;
		{[], []} -> perm
	    end,
    ets:insert(Ids, {K, C, Scope}),
    wx_colour(W, Which, tc(H, C, Which)).

wx_colour(W, fg, C) -> wxWindow:setForegroundColour(W, C);
wx_colour(W, bg, C) -> wxWindow:setBackgroundColour(W, C).

%% A colour as the theme in force shows it, as a background or as what is
%% drawn on one. Turned over, a bright text colour -- the lit green, the link
%% blue -- comes out mid-light on a pale ground, which does not read: in
%% the light theme what is drawn is never lighter than ?LIGHT_FG.
tc(H, C) -> tc(H, C, bg).

tc(H, C, Which) ->
    case is_light(H) of
	true when Which =:= bg -> light(C);
	true -> light_fg(C);
	false -> C
    end.

is_light(#{ids := Ids}) ->
    case ets:lookup(Ids, theme) of
	[{theme, "light", _}] -> true;
	_ -> false
    end.

%% F(Theme) when the theme changes, for what is coloured some other way
%% than by fg/3 and bg/3 (the log's lines). Key names it, once.
theme_hook(#{ids := Ids}, Key, F) ->
    ets:insert(Ids, {{theme_hook, Key}, F, perm}),
    ok.

-define(LIGHT_FG, 0.30).

%% Only what is light to begin with, what is drawn on the dark ground: a dark
%% colour is ink on a lit fill, and turns over with the fill.
light_fg({R, G, B}) ->
    {H, S, L} = hsl(R / 255, G / 255, B / 255),
    L1 = case L > 0.5 of
	     true  -> min(0.92 - 0.84 * L, ?LIGHT_FG);
	     false -> 0.92 - 0.84 * L
	 end,
    {R1, G1, B1} = rgb(H, S, L1),
    {round(R1 * 255), round(G1 * 255), round(B1 * 255)}.

%%% A BUTTON as wse draws one: flat, square, a line round it, lit in the
%%% panel's blue when it is on. Drawn here, as GTK's own are round and take
%%% no colour. Opts:
%%%
%%%   click => fun()       on a press
%%%   down, up => fun()    held: pressed, and let go (or dragged off)
%%%   min_w => Px          at least this wide
%%%
%%% Its colours are the window's own, set by bg/3 and fg/3, so the theme and
%%% a switch's lit colour reach it as they reach anything.

-define(BTN_BG, {51, 51, 51}).
-define(BTN_FG, {204, 204, 204}).
-define(BTN_ON, {51, 170, 255}).

btn(H, Parent, Label, Opts) ->
    W = wxPanel:new(Parent, [{style, ?wxBORDER_NONE}]),
    wxWindow:setFont(W, font(H)),
    Scope = case ets:lookup(maps:get(ids, H), colour_scope) of
		[{_, Sc, _}] -> Sc;
		[] -> perm
	    end,
    register(H, {btn, W}, #{label => Label, on => false, enabled => true,
			    min_w => maps:get(min_w, Opts, 0)}, Scope),
    bg(H, W, ?BTN_BG),
    fg(H, W, ?BTN_FG),
    btn_size(W, Label, maps:get(min_w, Opts, 0)),
    wxPanel:connect(W, paint, [{callback, fun(_E, _O) -> btn_paint(H, W) end}]),
    Live = fun() -> maps:get(enabled, btn_state(H, W)) end,
    case Opts of
	#{click := F} ->
	    wxWindow:connect(W, left_down,
			     [{callback, fun(_E, _O) -> Live() andalso F() end}]);
	#{down := D, up := U} ->
	    Held = fun(E, _O) -> Live() andalso D(), wxEvent:skip(E) end,
	    Off = fun(_E, _O) -> Live() andalso U() end,
	    wxWindow:connect(W, left_down, [{callback, Held}]),
	    wxWindow:connect(W, left_up, [{callback, Off}]),
	    wxWindow:connect(W, leave_window, [{callback, Off}]);
	_ -> ok
    end,
    W.

btn_size(W, Label, MinW) ->
    {Tw, Th, _, _} = wxWindow:getTextExtent(W, Label),
    wxWindow:setMinSize(W, {max(MinW, Tw + 18), Th + 8}).

btn_state(#{ids := Ids}, W) ->
    case ets:lookup(Ids, {btn, W}) of
	[{_, St, _}] -> St;
	[] -> #{label => "", on => false, enabled => true, min_w => 0}
    end.

btn_set(H = #{ids := Ids}, W, Kv) ->
    [{K, St, Sc}] = ets:lookup(Ids, {btn, W}),
    ets:insert(Ids, {K, maps:merge(St, Kv), Sc}),
    wxWindow:refresh(W),
    H.

%% A CHOICE as a button: what is chosen, and a menu of the rest on a click --
%% the flat look of the bar, where a wxChoice is the desktop's own. Pick(I)
%% with I from 1.
menu_btn(H, Parent, Labels, Ix0, Pick) ->
    Mark = fun(I) -> lists:nth(I, Labels) ++ " \x{25BE}" end,
    W = btn(H, Parent, Mark(Ix0 + 1), #{}),
    %% as wide as its widest choice, so picking one does not move the bar
    MinW = lists:max([element(1, wxWindow:getTextExtent(W, Mark(I))) + 18
		      || I <- lists:seq(1, length(Labels))]),
    btn_set(H, W, #{min_w => MinW}),
    btn_label(H, W, Mark(Ix0 + 1)),
    Show = fun(_, _) ->
		   M = wxMenu:new(),
		   [wxMenu:append(M, I, L)
		    || {I, L} <- lists:zip(lists:seq(1, length(Labels)), Labels)],
		   wxMenu:connect(M, command_menu_selected,
				  [{callback, fun(#wx{id = I}, _) ->
						      btn_label(H, W, Mark(I)),
						      Pick(I)
					      end}]),
		   {_, Bh} = wxWindow:getSize(W),
		   wxWindow:popupMenu(W, M, [{pos, {0, Bh}}]),
		   wxMenu:destroy(M)
	   end,
    wxWindow:connect(W, left_down, [{callback, Show}]),
    W.

%% A toggle's state: lit, or not.
btn_on(H, W, On) ->
    case On of
	true  -> bg(H, W, ?BTN_ON), fg(H, W, {17, 17, 17});
	false -> bg(H, W, ?BTN_BG), fg(H, W, ?BTN_FG)
    end,
    btn_set(H, W, #{on => On}),
    ok.

btn_enable(H, W, On) ->
    btn_set(H, W, #{enabled => On}),
    ok.

btn_label(H, W, Label) ->
    btn_size(W, Label, maps:get(min_w, btn_state(H, W), 0)),
    btn_set(H, W, #{label => Label}),
    ok.

btn_paint(H, W) ->
    #{label := L, on := On, enabled := En} = btn_state(H, W),
    DC = wxPaintDC:new(W),
    {Ww, Wh} = wxWindow:getClientSize(W),
    Bg = wxWindow:getBackgroundColour(W),
    Fg = case En of
	     true  -> wxWindow:getForegroundColour(W);
	     false -> tc(H, {110, 110, 110}, fg)
	 end,
    Br = wxBrush:new(Bg),
    Pen = wxPen:new(case is_light(H) of
			true  -> {120, 120, 120};
			false -> {85, 85, 85}
		    end, [{width, 1}]),
    wxDC:setBrush(DC, Br),
    wxDC:setPen(DC, Pen),
    wxDC:drawRectangle(DC, {0, 0, Ww, Wh}),
    Font = font(H),
    wxFont:setWeight(Font, case On of true -> ?wxFONTWEIGHT_BOLD;
				       false -> ?wxFONTWEIGHT_NORMAL end),
    wxDC:setFont(DC, Font),
    wxDC:setTextForeground(DC, Fg),
    {Tw, Th} = wxDC:getTextExtent(DC, L),
    wxDC:drawText(DC, L, {(Ww - Tw) div 2, (Wh - Th) div 2}),
    wxFont:setWeight(Font, ?wxFONTWEIGHT_NORMAL),
    wxBrush:destroy(Br),
    wxPen:destroy(Pen),
    wxPaintDC:destroy(DC).

%% A GROUP of buttons that go together: a line round them and their name on
%% it, small, as a fieldset's legend in wse. Back: the panel to make them in
%% and the sizer to put them in.
group_font() ->
    wxFont:new(8, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL,
	       ?wxFONTWEIGHT_NORMAL).

btn_group(H, Parent, Title) ->
    G = wxPanel:new(Parent),
    bg(H, G, ?BG),
    Legend = " " ++ Title ++ " ",
    Font = group_font(),
    {Lw, Lh, _, _} = wxWindow:getTextExtent(G, Legend, [{theFont, Font}]),
    wxFont:destroy(Font),
    %% room on top for the name, and at least its width
    S = wxBoxSizer:new(?wxVERTICAL),
    wxWindow:setSizer(G, S),
    wxSizer:add(S, Lw + 16, Lh + 2),
    In = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(S, In, [{flag, ?wxLEFT bor ?wxRIGHT bor ?wxBOTTOM}, {border, 4}]),
    wxPanel:connect(G, paint,
		    [{callback,
		      fun(_E, _O) ->
			      DC = wxPaintDC:new(G),
			      {Gw, Gh} = wxWindow:getClientSize(G),
			      Light = is_light(H),
			      Pen = wxPen:new(case Light of
						  true  -> {150, 150, 150};
						  false -> {68, 68, 68}
					      end, [{width, 1}]),
			      wxDC:setPen(DC, Pen),
			      wxDC:setBrush(DC, ?wxTRANSPARENT_BRUSH),
			      Y0 = Lh div 2,
			      wxDC:drawRectangle(DC, {0, Y0, Gw, Gh - Y0}),
			      F = group_font(),
			      wxDC:setFont(DC, F),
			      wxDC:setBackgroundMode(DC, ?wxSOLID),
			      wxDC:setTextBackground(DC, wxWindow:getBackgroundColour(G)),
			      wxDC:setTextForeground(DC, tc(H, ?DIM, fg)),
			      wxDC:drawText(DC, Legend, {6, 0}),
			      wxFont:destroy(F),
			      wxPen:destroy(Pen),
			      wxPaintDC:destroy(DC)
		      end}]),
    {G, In}.

%%% A RICH text control (the log, the chat): text in colours of its own
%%% kinds, Colour(Light, Kind) -> {R, G, B}, a colour for each theme. What is
%%% in it is kept as spans, {Kind, From, To} by position, so a change of
%%% theme colours it all again.

rich(H, Ctrl, Colour) ->
    ets:insert(maps:get(ids, H), {{rich, Ctrl}, {Colour, []}, perm}),
    theme_hook(H, {rich, Ctrl}, fun(_T) -> restyle(H, Ctrl) end).

rich_add(H, Ctrl, Kind, Text) ->
    {Colour, Spans} = rich_get(H, Ctrl),
    From = wxTextCtrl:getLastPosition(Ctrl),
    A = attr(H, Ctrl, Colour(is_light(H), Kind)),
    wxTextCtrl:setDefaultStyle(Ctrl, A),
    wxTextCtrl:appendText(Ctrl, Text),
    wxTextAttr:destroy(A),
    To = wxTextCtrl:getLastPosition(Ctrl),
    rich_put(H, Ctrl, {Colour, [{Kind, From, To} | Spans]}).

%% The first N lines gone.
rich_trim(H, Ctrl, N) ->
    Cut = wxTextCtrl:xYToPosition(Ctrl, 0, N),
    wxTextCtrl:remove(Ctrl, 0, Cut),
    {Colour, Spans} = rich_get(H, Ctrl),
    rich_put(H, Ctrl, {Colour, [{K, max(0, F - Cut), T - Cut}
				|| {K, F, T} <- Spans, T > Cut]}).

rich_clear(H, Ctrl) ->
    wxTextCtrl:clear(Ctrl),
    {Colour, _} = rich_get(H, Ctrl),
    rich_put(H, Ctrl, {Colour, []}).

rich_get(#{ids := Ids}, Ctrl) ->
    [{_, V, _}] = ets:lookup(Ids, {rich, Ctrl}),
    V.

rich_put(#{ids := Ids}, Ctrl, V) ->
    ets:insert(Ids, {{rich, Ctrl}, V, perm}),
    ok.

restyle(H, Ctrl) ->
    {Colour, Spans} = rich_get(H, Ctrl),
    Light = is_light(H),
    [begin
	 A = attr(H, Ctrl, Colour(Light, K)),
	 wxTextCtrl:setStyle(Ctrl, F, T, A),
	 wxTextAttr:destroy(A)
     end || {K, F, T} <- merge(lists:reverse(Spans))],
    ok.

%% The text's colour on the control's own ground: a span keeps the ground it
%% was written on, so the theme's must be said too.
attr(H = #{ids := Ids}, Ctrl, Fg) ->
    case ets:lookup(Ids, {colour, Ctrl, bg}) of
	[{_, Bg, _}] -> wxTextAttr:new(Fg, [{colBack, tc(H, Bg, bg)}]);
	[] -> wxTextAttr:new(Fg)
    end.

merge([{K, F, _}, {K, _, T} | Ss]) -> merge([{K, F, T} | Ss]);
merge([S | Ss]) -> [S | merge(Ss)];
merge([]) -> [].

light({R, G, B}) ->
    {H, S, L} = hsl(R / 255, G / 255, B / 255),
    {R1, G1, B1} = rgb(H, S, 0.92 - 0.84 * L),
    {round(R1 * 255), round(G1 * 255), round(B1 * 255)}.

hsl(R, G, B) ->
    Mx = max(R, max(G, B)), Mn = min(R, min(G, B)),
    L = (Mx + Mn) / 2,
    case Mx == Mn of
	true -> {0.0, 0.0, L};
	false ->
	    D = Mx - Mn,
	    S = case L > 0.5 of true -> D / (2 - Mx - Mn); false -> D / (Mx + Mn) end,
	    H = if Mx == R -> (G - B) / D + (case G < B of true -> 6; false -> 0 end);
		   Mx == G -> (B - R) / D + 2;
		   true    -> (R - G) / D + 4
		end,
	    {H / 6, S, L}
    end.

rgb(_H, S, L) when S == 0 -> {L, L, L};
rgb(H, S, L) ->
    Q = case L < 0.5 of true -> L * (1 + S); false -> L + S - L * S end,
    P = 2 * L - Q,
    {hue(P, Q, H + 1/3), hue(P, Q, H), hue(P, Q, H - 1/3)}.

hue(P, Q, T0) ->
    T = if T0 < 0 -> T0 + 1; T0 > 1 -> T0 - 1; true -> T0 end,
    if T < 1/6 -> P + (Q - P) * 6 * T;
       T < 1/2 -> Q;
       T < 2/3 -> P + (Q - P) * (2/3 - T) * 6;
       true    -> P
    end.

%% A label as written: setLabel reads `&' as a mnemonic, so `B1 && B2' would
%% show as `B1 & B2' -- each `&' is doubled. (This wx has no setLabelText.)
label(W, Text) ->
    wxControl:setLabel(W, lists:flatmap(fun($&) -> "&&"; (C) -> [C] end,
					lists:flatten(Text))).

%% A bitmap shown in a panel, {Panel, Bitmap}: draw with redraw/3.
canvas(Parent, W, H, Bg) ->
    P = wxPanel:new(Parent, [{size, {W, H}}]),
    wxWindow:setMinSize(P, {W, H}),
    Bmp = wxBitmap:new(W, H),
    DC = wxMemoryDC:new(Bmp),
    rect(DC, {0, 0, W, H}, Bg),
    wxMemoryDC:destroy(DC),
    wxPanel:connect(P, paint, [{callback,
				fun(_E, _O) ->
					PDC = wxPaintDC:new(P),
					wxDC:drawBitmap(PDC, Bmp, {0, 0}),
					wxPaintDC:destroy(PDC)
				end}]),
    {P, Bmp}.

redraw(P, Bmp, Draw) ->
    DC = wxMemoryDC:new(Bmp),
    Draw(DC),
    wxMemoryDC:destroy(DC),
    wxWindow:refresh(P, [{eraseBackground, false}]).

rect(DC, Rect, Col) ->
    Br = wxBrush:new(Col),
    wxDC:setBrush(DC, Br),
    wxDC:setPen(DC, ?wxTRANSPARENT_PEN),
    wxDC:drawRectangle(DC, Rect),
    wxBrush:destroy(Br).

relayout(Win) ->
    wxWindow:layout(Win),
    wxWindow:refresh(Win).

%% Win and every window above it laid out again, to the top: a piece that
%% grew -- a table shown -- pushes everything below it.
relayout_up(Win) ->
    wxWindow:layout(Win),
    case wxWindow:isTopLevel(Win) of
	true  -> ok;
	false -> relayout_up(wxWindow:getParent(Win))
    end.

%% A piece by its name, for as long as Scope lives: perm until the next
%% rebuild, rung until the code view draws another tab, answer until varp's
%% next answer. forget/2 drops a scope.
register(H, Id, What) -> register(H, Id, What, perm).

register(#{ids := Ids}, Id, What, Scope) -> ets:insert(Ids, {Id, What, Scope}).

forget(#{ids := Ids}, Scope) -> ets:match_delete(Ids, {'_', '_', Scope}).

%% F run with Scope as the scope of the colours set in it, so forget/2 drops
%% them with the windows registered there. theme/2 sets the colour of every
%% window it knows, and one that is gone takes the whole emulator down -- a
%% segfault, not an error.
in_scope(#{ids := Ids}, Scope, F) ->
    ets:insert(Ids, {colour_scope, Scope, perm}),
    try F() after ets:delete(Ids, colour_scope) end.

lookup(#{ids := Ids}, Id) ->
    case ets:lookup(Ids, Id) of
	[{_, W, _}] -> {ok, W};
	[]          -> error
    end.

%% And the scope it was registered in.
lookup_scope(#{ids := Ids}, Id) ->
    case ets:lookup(Ids, Id) of
	[{_, W, Scope}] -> {ok, W, Scope};
	[]              -> error
    end.

%% A css colour as the panel writes them -- #rgb, #rrggbb, rgb(r,g,b) -- as
%% {R, G, B}.
colour({_, _, _} = C) -> C;
colour("#" ++ [R, G, B]) ->
    {hex([R, R]), hex([G, G]), hex([B, B])};
colour("#" ++ [R1, R2, G1, G2, B1, B2]) ->
    {hex([R1, R2]), hex([G1, G2]), hex([B1, B2])};
colour("rgb(" ++ T) ->
    [R, G, B] = [list_to_integer(string:trim(X))
		 || X <- string:lexemes(string:trim(T, trailing, ")"), ",")],
    {R, G, B};
colour(Name) when is_list(Name) ->
    case candid:colour(Name, lamp, #{"color" => Name}) of
	{"#" ++ _ = C, _} -> colour(C);
	_ -> ?INK
    end;
colour(_) -> ?INK.

hex(S) -> list_to_integer(S, 16).

%% P percent of A over B, as css color-mix does.
mix(A, P, B) ->
    {Ra, Ga, Ba} = colour(A),
    {Rb, Gb, Bb} = colour(B),
    M = fun(X, Y) -> round(X * P / 100 + Y * (100 - P) / 100) end,
    {M(Ra, Rb), M(Ga, Gb), M(Ba, Bb)}.

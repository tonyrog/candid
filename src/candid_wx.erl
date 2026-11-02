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
-export([clear/2, message/3, chooser/3, panel/3, event/2]).
-export([status/3, trace_view/3, theme/2, view_buttons/4, mode/3]).
-export([paint/3, trace_clear/2, trace_column/3, plot/4]).
-export([fg/3, bg/3, tc/2]).
-export([colour/1, mix/3, font/1, label/2, relayout_up/1, canvas/4, redraw/3, register/3, register/4,
	 forget/2, lookup/2, click/3, frame_box/2, text/4]).
-export([dock_pane/4, dock_show/3]).                % the log's and the chat's                          % csp_code_wx's

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
    ets:delete_all_objects(Ids),
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
    X = wxButton:new(P, ?wxID_ANY, [{label, "close"}]),
    Pid = self(),
    wxButton:connect(X, command_button_clicked,
		     [{callback, fun(_E, _O) -> Pid ! Close end}]),
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
chooser(H, Root, #{file := Current, files := Files, target := Target,
		   period := Now, periods := Periods, views := Views,
		   chat := Chat}) ->
    %% Two rows: what runs and how, then what is shown.
    Bar = wxBoxSizer:new(?wxVERTICAL),
    Row1 = wxBoxSizer:new(?wxHORIZONTAL),
    Row2 = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Bar, Row1, []),
    wxSizer:add(Bar, Row2, []),
    In = fun(Row) -> fun(W) -> wxSizer:add(Row, W, [{flag, ?wxALL bor
						     ?wxALIGN_CENTER_VERTICAL},
						    {border, 3}]), W end end,
    Add = In(Row1),
    Add2 = In(Row2),
    Sel = Add(wxChoice:new(Root, ?wxID_ANY,
			   [{choices, [candid:shorten(F) || F <- Files]}])),
    wxChoice:setSelection(Sel, index_of(Current, Files)),
    wxChoice:connect(Sel, command_choice_selected, [{userData, {pick, Files}}]),
    Tgt = Add(wxTextCtrl:new(Root, ?wxID_ANY,
			     [{value, Target}, {size, {260, -1}},
			      {style, ?wxTE_PROCESS_ENTER}])),
    wxWindow:setToolTip(Tgt, "local, or a can interface: a csp of our own on "
			"that bus\nhost:port or /dev/tty...[@baud]: a node's "
			"console\nrom | eeprom: without or with the EEPROM patch\n"
			"image=SLOT: read a node's program from that flash slot"),
    wxTextCtrl:connect(Tgt, command_text_enter, [{userData, {bar_text, "target="}}]),
    Toggle = fun(Label, Tag) ->
		     B = Add(wxToggleButton:new(Root, ?wxID_ANY, Label)),
		     wxToggleButton:connect(B, command_togglebutton_clicked,
					    [{userData, {bar, Tag}}]),
		     B
	     end,
    RunB = Toggle("run", "mode=run"),
    PauseB = Toggle("pause", "mode=step"),
    OneB = Add(wxButton:new(Root, ?wxID_ANY, [{label, "step"}])),
    wxButton:connect(OneB, command_button_clicked, [{userData, {bar, "step=1"}}]),
    Add(text(H, Root, "tick", ?DIM)),
    Ps = lists:usort([Now | Periods]),
    Tick = Add(wxChoice:new(Root, ?wxID_ANY,
			    [{choices, [integer_to_list(P) ++ " ms" || P <- Ps]}])),
    wxChoice:setSelection(Tick, index_of(Now, Ps)),
    wxChoice:connect(Tick, command_choice_selected,
		     [{userData, {bar_choice, "period=",
				  [integer_to_list(P) || P <- Ps]}}]),
    Toggle2 = fun(Label, Tag) ->
		      B = Add2(wxToggleButton:new(Root, ?wxID_ANY, Label)),
		      wxToggleButton:connect(B, command_togglebutton_clicked,
					     [{userData, {bar, Tag}}]),
		      B
	      end,
    Vs = lists:append(
	   [[{{K, V}, begin
			  _ = (V =:= hd(Vals)) andalso
			      Add2(text(H, Root, "  " ++ K, ?DIM)),
			  Toggle2(V, K ++ "=" ++ V)
		      end} || V <- Vals] || {K, Vals} <- Views]),
    Chat andalso begin
		     B = Add2(wxButton:new(Root, ?wxID_ANY, [{label, "chat"}])),
		     wxButton:connect(B, command_button_clicked,
				      [{userData, {bar, "chat=toggle"}}])
		 end,
    LogB = Add2(wxButton:new(Root, ?wxID_ANY, [{label, "log"}])),
    wxButton:connect(LogB, command_button_clicked, [{userData, {bar, "log=toggle"}}]),
    wxSizer:add(wxWindow:getSizer(Root), Bar, [{flag, ?wxALL bor ?wxEXPAND},
					       {border, 4}]),
    relayout(Root),
    {pick, #{event => bar, run => RunB, pause => PauseB, one => OneB,
	     views => maps:from_list(Vs)}}.

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
event(_Ids, #wx{userData = {pick, Files}, event = #wxCommand{commandInt = I}}) ->
    {pick, lists:nth(I + 1, Files)};
event(_Ids, #wx{userData = {bar_text, Pre}, event = #wxCommand{cmdString = S}}) ->
    {bar, Pre ++ S};
event(_Ids, #wx{userData = {bar_choice, Pre, Vals},
		event = #wxCommand{commandInt = I}}) ->
    {bar, Pre ++ lists:nth(I + 1, Vals)};
event(_Ids, #wx{userData = {code_choice, Pre, Vals},
		event = #wxCommand{commandInt = I}}) ->
    {code, Pre ++ lists:nth(I + 1, Vals)};
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
    [wx_colour(W, Which, tc(H, C)) || {{colour, W, Which}, C, _} <- ets:tab2list(Ids)],
    [wxWindow:refresh(W) || {theme_root, W, _} <- ets:lookup(Ids, theme_root)],
    ok.

view_buttons(_H, #{views := Views}, Key, V) ->
    [wxToggleButton:setValue(B, Val =:= V)
     || {{K1, Val}, B} <- maps:to_list(Views), K1 =:= Key],
    ok.

mode(_H, #{run := RunB, pause := PauseB, one := OneB}, Step) ->
    wxToggleButton:setValue(RunB, not Step),
    wxToggleButton:setValue(PauseB, Step),
    %% the step button is only live while stopped
    wxWindow:enable(OneB, [{enable, Step}]).

paint(H, Node, V) ->
    paint1(H, Node, V).

%% The trace wraps: clear right of the labels.
trace_clear(_H, {P, Bmp}) ->
    redraw(P, Bmp, fun(DC) -> rect(DC, {?GUTTER, 0, ?TRACE_W, 4096}, {26, 26, 26})
		   end).

%% One column: x, y, colour, x, y, colour ...
trace_column(_H, {P, Bmp}, Items) ->
    redraw(P, Bmp, fun(DC) -> column(DC, Items) end).

column(DC, [X, Y, C | T]) ->
    rect(DC, {X, Y, ?STEP, 3}, colour(C)),
    column(DC, T);
column(_DC, []) -> ok.

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
		 label(B, maps:get(label, Look)),
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
    B = wxButton:new(Left, ?wxID_ANY, [{label, integer_to_list(Idle)},
				       {size, {60, -1}}]),
    wxWindow:setFont(B, font(H)),
    wxButton:connect(B, command_button_clicked, [{userData, {widget, Name}}]),
    wxSizer:add(Row, B, []),
    {switch, B, Hue, Idle}.

%% Held down rather than latched: the pressed level while held, the resting
%% one on release -- 1 and 0, or 0 and 1 for a button to ground.
push(H, Left, Row, Name, Look = #{colour := Hue}) ->
    Idle = maps:get(idle, Look, 0),
    B = wxButton:new(Left, ?wxID_ANY, [{label, integer_to_list(Idle)},
				       {size, {60, -1}}]),
    wxWindow:setFont(B, font(H)),
    Pid = self(),
    Send = fun(V) -> fun(_E, O) ->
			     Pid ! {candid_wx, {widget, Name ++ "=" ++
						integer_to_list(V)}},
			     wxEvent:skip(O)
		     end
	   end,
    wxWindow:connect(B, left_down, [{callback, Send(1 - Idle)}]),
    wxWindow:connect(B, left_up, [{callback, Send(Idle)}]),
    %% dragging off must not leave it held
    wxWindow:connect(B, leave_window, [{callback, Send(Idle)}]),
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
    wxButton:setLabel(B, case V of 0 -> "0"; _ -> "1" end),
    wxWindow:refresh(B);
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

set_colour(#{ids := Ids} = H, W, Which, C0) ->
    C = colour(C0),
    ets:insert(Ids, {{colour, W, Which}, C, perm}),
    wx_colour(W, Which, tc(H, C)).

wx_colour(W, fg, C) -> wxWindow:setForegroundColour(W, C);
wx_colour(W, bg, C) -> wxWindow:setBackgroundColour(W, C).

%% A colour as the theme in force shows it.
tc(#{ids := Ids}, C) ->
    case ets:lookup(Ids, theme) of
	[{theme, "light", _}] -> light(C);
	_ -> C
    end.

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

lookup(#{ids := Ids}, Id) ->
    case ets:lookup(Ids, Id) of
	[{_, W, _}] -> {ok, W};
	[]          -> error
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

%%% candid's renderer for the browser, through wse: everything the panel
%%% puts on a page and every wse call it makes. candid (the core) decides what
%%% there is and what it shows; this draws it, and turns the browser's
%%% notifies back into what the core reads (event/2).
%%%
%%% Every function takes the wse handle first. What it creates it hands back
%%% as handles the core keeps and gives back without looking inside: a node, a
%%% trace, a plot.
%%%
%%% The trace and the plots are drawn in the pixel coordinates of candid.hrl,
%%% which the core computes in; a renderer only has to put the dots there.

-module(candid_wse).

-export([start/2, code_view/0, chat_view/0]).
-export([clear/2, message/3, chooser/3, panel/3, event/2]).
-export([status/3, trace_view/3, theme/2, view_buttons/4, mode/3]).
-export([paint/3, trace_clear/2, trace_column/3, plot/4]).

-include("candid.hrl").

-define(TRACE_BOX, "flex:none;max-height:35vh;overflow:auto;").  % at the bottom
-define(LAMP,     "display:inline-block;width:18px;height:18px;"
		  "border-radius:9px;border:1px solid #555;").
-define(PIXEL,    "display:inline-block;width:22px;height:22px;"
		  "border:1px solid #444;margin-right:2px;"
		  "vertical-align:middle;").
-define(LAMP_ON,  "background:#3f3;box-shadow:0 0 8px #3f3").
-define(LAMP_OFF, "background:#252525").
%% The glass. `shape=round' is a CRT face: the corners of the value range fall
%% outside it, which is a choice and not a bug -- a channel at both extremes at
%% once is off the glass. shape=square keeps all of it, and is the default for
%% that reason.
-define(GLASS,    "vertical-align:top;cursor:crosshair;background:").
-define(FLAT,     "border:1px solid #333;").
-define(ROUND,    "border-radius:50%;border:3px solid #2b2b2b;"
		  "box-shadow:0 0 0 4px #141414,"
		  "0 0 18px rgba(90,255,160,0.13);").


%%% --------------------------------------------------------------- starting
%%%
%%% wse_server speaks websocket on /websession and NOTHING else -- a plain GET
%%% for the page falls out of its handshake with a case_clause. So the page needs
%%% an ordinary web server: inets serves priv/ for panel.html, and ALIASES
%%% wse's own priv/ at /js for ej.js and wse.js. Copying those two in would
%%% work and is what one usually does, but then they silently diverge from the
%%% wse that is actually serving the websocket.


start(WsPort, HttpPort) ->
    ok = ensure_inets(),
    {ok, _} = inets:start(httpd,
			  [{port, HttpPort},
			   {server_name, "candid"},
			   {server_root, candid:priv_dir()},
			   {document_root, candid:priv_dir()},
			   {alias, {"/js", wse_priv()}},
			   {bind_address, {127,0,0,1}},
			   {mime_types, [{"html","text/html"},
					 {"js","application/javascript"},
					 {"css","text/css"}]}]),
    application:ensure_all_started(rester),
    application:load(wse),
    application:start(ellm),
    {ok, _} = wse_server:start(WsPort),
    io:format("panel:  http://localhost:~w/panel.html~n", [HttpPort]),
    io:format("wse:    ws://localhost:~w/websession~n", [WsPort]),
    io:format("js from ~s~n", [wse_priv()]),
    ok.

ensure_inets() ->
    case application:ensure_all_started(inets) of
	{ok, _}                       -> ok;
	{error, {already_started, _}} -> ok;
	Err                           -> Err
    end.

%% Who draws the code view and the chat pane here.
code_view() -> csp_code_wse.
chat_view() -> csp_chat_wse.

%%% ------------------------------------------------------------ the page

%% Where the panel goes, emptied: a rebuild starts the page over.
clear(Ws, Where) ->
    Root = wse:id(Where),
    wse:set(Ws, Root, "innerHTML", ""),
    Root.

message(Ws, Root, Str) ->
    text(Ws, Root, Str).

%% The page under the bar. The TOP frame is where the program is: State,
%% cycle and clock, the goal and solve, varp's answer, the values. Under it
%% the devices on the left and the code view on the right, each scrolling on
%% its own, and the trace at the bottom -- so the rule that lights and the
%% lamp it drives are side by side, and neither scrolls the other out of view.
%%
%% Spec: rows [{Widget, Look}], pixels [{Name, Look}], plots (groups),
%% traces [Look]. Back: the nodes by name, the plot groups with their canvas
%% in them, the trace, the status boxes, and the frames the code view draws
%% into.
panel(Ws, Root, #{rows := Rows, pixels := Pixels, plots := Plots0,
		  traces := Traces}) ->
    style(Ws, Root, "display:flex;flex-direction:column;"
	  "height:calc(100vh - 24px)"),
    Top = box(Ws, Root, "flex:none;border-bottom:1px solid #333;"
	      "padding-bottom:4px;margin-bottom:8px"),
    Status = box(Ws, Top, "display:flex;align-items:center;gap:10px;"
		 "flex-wrap:wrap;margin-bottom:6px"),
    StateBox = status_box(Ws, Status, "csp_st"),
    Clock = status_box(Ws, Status, "csp_clock"),
    LinkBox = status_box(Ws, Status, "csp_link"),
    Main = box(Ws, Root, "flex:1;min-height:0;display:flex;gap:32px"),
    Left = box(Ws, Main, "flex:none;overflow:auto;padding-right:8px"),
    Right = box(Ws, Main, "flex:1;min-width:0;overflow:auto"),
    TraceBox = box(Ws, Root, ?TRACE_BOX "display:none"),
    RowNodes = [{Name, row(Ws, Left, W, Look)} || {W = {_, Name, _}, Look} <- Rows],
    PixNodes = strip(Ws, Left, Pixels),
    {Plots, PlotNodes} = plot_panels(Ws, Left, Plots0),
    Trace = canvas(Ws, TraceBox, Traces),
    #{nodes => maps:from_list(RowNodes ++ PixNodes ++ PlotNodes),
      plots => Plots, trace => Trace, trace_box => TraceBox,
      state_box => StateBox, clock_box => Clock, link_box => LinkBox,
      code => #{code => Right, status => Status, top => Top}}.

%% What the browser said, as the core reads it. Ids: the chooser's event
%% (sel), the bar's (run) and the code view's (code); any other is a widget.
event(#{sel := Id}, {notify, Id, _Local, File}) -> {pick, File};
event(#{run := Id}, {notify, Id, _Local, Tag})  -> {bar, Tag};
event(#{code := Id}, {notify, Id, _Local, Tag}) -> {code, Tag};
event(_Ids, {notify, _Id, _Local, Data})        -> {widget, Data};
event(_Ids, {closed, _})                        -> closed;
event(_Ids, _Msg)                               -> none.

%%% ------------------------------------------------------------ what changes

%% A status box's text: the link, the clock.
status(Ws, {B, F}, Text) ->
    wse:cast(Ws, F, "call", [null, B, lists:flatten(Text)]).

trace_view(Ws, TraceBox, Show) ->
    style(Ws, TraceBox, [?TRACE_BOX, case Show of true  -> "display:block";
						  false -> "display:none"
				     end]).

%% The bar's view buttons of Key: the one showing V lit.
view_buttons(Ws, #{views := Views}, Key, V) ->
    [style(Ws, B, btn_style(Val =:= V))
     || {{K1, Val}, B} <- maps:to_list(Views), K1 =:= Key],
    ok.

%% Which of run, pause and step is in force, so the bar says where you are.
mode(Ws, #{run := RunB, pause := PauseB, one := OneB}, Step) ->
    style(Ws, RunB,   btn_style(not Step)),
    style(Ws, PauseB, btn_style(Step)),
    %% the step button is only live while stopped
    style(Ws, OneB, [btn_style(false),
		     case Step of true -> ";opacity:1"; false -> ";opacity:0.4" end]).

paint(Ws, Node, V) ->
    paint1(Ws, Node, V).

%% The trace wraps: clear right of the labels.
trace_clear(Ws, {Ctx, _Paint}) ->
    wse:cast(Ws, Ctx, "clearRect", [?GUTTER, 0, ?TRACE_W, 4096]).

%% One column: x, y, colour, x, y, colour ... -- see painter/1.
trace_column(Ws, {Ctx, Paint}, Items) ->
    wse:cast(Ws, Paint, "call", [null, Ctx, wse:array(Items)]).

%% One frame of a plot: the decay Keep, then per channel the segment and its
%% colour (x0, y0, x1, y1, colour ...) -- see plotter/1.
plot(Ws, #{ctx := Ctx, plot := Plot, round := Rnd, clip := Clip, beam := Beam,
	   dot := Dot, glow := Glow, step := Step}, Keep, Items) ->
    wse:cast(Ws, Plot, "call",
	     [null, Ctx, ?PLOT_W, ?PLOT_W, Keep, Rnd, Clip, Beam, Dot,
	      Glow, Step, wse:array(Items)]).

%%% ------------------------------------------------------------ building

status_box(Ws, Row, Id) ->
    B = wse:createElement(Ws, "span"),
    wse:set(Ws, B, "id", Id),
    wse:setStyle(Ws, B, "padding:3px 10px;border:1px solid #555;color:#ddd;"
		 "font:13px monospace;white-space:pre"),
    wse:appendChild(Ws, Row, B),
    {B, wse:newf(Ws, "e,t", "{ e.textContent = t; }")}.

box(Ws, Parent, Style) ->
    D = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, D, Style),
    wse:appendChild(Ws, Parent, D),
    D.

%% LIGHT is the dark panel inverted and turned back to its own hues, on a pale
%% blue page: every colour in the panel is written inline, and one filter on
%% the root is the change that reaches all of them, the canvases included. A
%% lamp stays red; a glow becomes a shade instead, which reads fine on white.
theme(Ws, T) ->
    {Bg, Filter} = case T of
		       "light" -> {"#dce6f2", "invert(0.92) hue-rotate(180deg) saturate(1.8)"};
		       _       -> {"#121212", "none"}
		   end,
    F = wse:newf(Ws, "bg,f",
		 "{ document.body.style.background = bg;"
		 "  document.getElementById('panel').style.filter = f; }"),
    wse:cast(Ws, F, "call", [null, Bg, Filter]).

%% The bar: the program chooser -- every .csp under demo/ and the tree's
%% examples/, so another program is a pick rather than an edit of the page --
%% then run/step, the target, the tick and the views. Spec: file, files,
%% target, period, periods, views [{Key, Vals}], chat (whether there is one).
chooser(Ws, Root, Spec = #{file := Current, files := Files}) ->
    Bar = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Bar, "font:14px monospace;color:#888;margin-bottom:12px"),
    Sel = wse:createElement(Ws, "select"),
    wse:setStyle(Ws, Sel, "font:14px monospace;background:#222;color:#eee;"
		 "border:1px solid #555;padding:3px"),
    lists:foreach(
      fun(F) ->
	      O = wse:createElement(Ws, "option"),
	      wse:set(Ws, O, "value", F),
	      wse:appendChild(Ws, O, wse:createTextNode(Ws, candid:shorten(F))),
	      case F =:= Current of
		  true  -> wse:set(Ws, O, "selected", true);
		  false -> ok
	      end,
	      wse:appendChild(Ws, Sel, O)
      end, Files),
    {ok, Id} = wse:create_event(Ws),
    %% `this` in an onchange assigned this way is the select, so the new
    %% filename rides along and the loop needs no reverse map.
    Func = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			", this.value); }"),
    wse:set(Ws, Sel, "onchange", Func),
    wse:appendChild(Ws, Bar, Sel),
    Run = runstep(Ws, Bar, Spec),
    wse:appendChild(Ws, Root, Bar),
    {Id, Run}.

%% Run or step, and they are not the same clock.
%%
%% RUNNING: the panel sends /commit on a timer, and a `> X = 1' from a widget
%% runs a cycle of its own -- which is what you want while poking at a thing.
%%
%% STEPPING: /pause, so nothing moves until asked. Values set from widgets go in
%% WITHOUT running a cycle, and one /step runs exactly one with all of them
%% committed together -- the way a board commits every DIN at the top of a cycle.
%% That is also what a replayed model trace needs, since a trace step carries
%% several inputs belonging to the same instant.
runstep(Ws, Bar, Spec = #{views := Vs, chat := Chat}) ->
    Wrap = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Wrap, "margin-left:16px"),
    {ok, Id} = wse:create_event(Ws),
    Mk = fun(Label, Tag) ->
		 B = wse:createElement(Ws, "button"),
		 wse:setStyle(Ws, B, lists:flatten(btn_style(false))),
		 wse:appendChild(Ws, B, wse:createTextNode(Ws, Label)),
		 F = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
				  ", '" ++ Tag ++ "'); }"),
		 wse:set(Ws, B, "onclick", F),
		 wse:appendChild(Ws, Wrap, B),
		 B
	 end,
    target_field(Ws, Wrap, Id, maps:get(target, Spec)),
    RunB  = Mk("run",   "mode=run"),
    PauseB = Mk("pause", "mode=step"),
    OneB  = Mk("step",  "step=1"),
    %% The tick, on the SAME event as the buttons: the loop already tells the
    %% bar's events from a widget's by the id, and tags its payloads, so this
    %% needs no second wire. `period=25' lands in control/4 beside `mode=run'.
    tick_select(Ws, Wrap, Id, maps:get(period, Spec), maps:get(periods, Spec)),
    %% What is shown, on the same event: `trace=show' and the like.
    Group = fun(Label, Key, Vals) ->
		    L = wse:createElement(Ws, "span"),
		    wse:setStyle(Ws, L, "margin:0 6px 0 16px;color:#888;"
				 "font:12px monospace"),
		    wse:appendChild(Ws, L, wse:createTextNode(Ws, Label)),
		    wse:appendChild(Ws, Wrap, L),
		    [{{Key, V}, Mk(V, Key ++ "=" ++ V)} || V <- Vals]
	    end,
    Views = lists:append([Group(case K of "theme" -> ""; _ -> K end, K, Vals)
			  || {K, Vals} <- Vs]),
    %% Only when there is a chat to open: ellm on the path, not switched off.
    Chat andalso
	begin
	    L = wse:createElement(Ws, "span"),
	    wse:setStyle(Ws, L, "margin-left:16px"),
	    wse:appendChild(Ws, Wrap, L),
	    Mk("chat", "chat=toggle")
	end,
    wse:appendChild(Ws, Bar, Wrap),
    #{event => Id, run => RunB, pause => PauseB, one => OneB,
      views => maps:from_list(Views)}.

%% Where the program runs: a csp of our own, or a node. Read by
%% csp_link:target/1, sent on Enter.
target_field(Ws, Wrap, Id, Target) ->
    In = wse:createElement(Ws, "input"),
    wse:set(Ws, In, "type", "text"),
    wse:set(Ws, In, "value", Target),
    wse:set(Ws, In, "placeholder",
	    "local | can0 | host:port | /dev/ttyUSB0@115200  [rom|eeprom] "
	    "[image=A]"),
    wse:set(Ws, In, "title",
	    "local, or a can interface: a csp of our own on that bus\n"
	    "host:port or /dev/tty...[@baud]: a node's console\n"
	    "rom | eeprom: without or with the EEPROM patch\n"
	    "image=SLOT: read a node's program from that flash slot"),
    wse:setStyle(Ws, In, "width:24em;margin-right:12px;font:12px monospace;"
		 "background:#222;color:#eee;border:1px solid #555;"
		 "padding:3px"),
    F = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
		     ", 'target=' + this.value); }"),
    wse:set(Ws, In, "onchange", F),
    wse:appendChild(Ws, Wrap, In),
    In.

tick_select(Ws, Wrap, Id, Now, Periods) ->
    Lbl = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Lbl, "margin-left:12px;color:#888;font:12px monospace"),
    wse:appendChild(Ws, Lbl, wse:createTextNode(Ws, "tick")),
    wse:appendChild(Ws, Wrap, Lbl),
    Sel = wse:createElement(Ws, "select"),
    wse:setStyle(Ws, Sel, "margin-left:6px;font:12px monospace;background:#222;"
		 "color:#eee;border:1px solid #555;padding:2px"),
    lists:foreach(
      fun(Ms) ->
	      O = wse:createElement(Ws, "option"),
	      wse:set(Ws, O, "value", Ms),
	      wse:appendChild(Ws, O, wse:createTextNode(
					Ws, integer_to_list(Ms) ++ " ms")),
	      case Ms =:= Now of
		  true  -> wse:set(Ws, O, "selected", true);
		  false -> ok
	      end,
	      wse:appendChild(Ws, Sel, O)
      end, lists:usort([Now | Periods])),
    F = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
	    ", 'period=' + this.value); }"),
    wse:set(Ws, Sel, "onchange", F),
    wse:appendChild(Ws, Wrap, Sel),
    Sel.

btn_style(Active) ->
    ["font:13px monospace;padding:3px 9px;margin-right:4px;"
     "border:1px solid #555;",
     case Active of
	 true  -> "background:#3af;color:#111;font-weight:bold";
	 false -> "background:#333;color:#ccc"
     end].

%% A row per widget: the label, then the control. The lamp node is what we
%% restyle when the value changes, so it is what we keep -- together with the
%% look, which says what colour to restyle it with and how to print the number.
row(Ws, Root, {Kind, Name, _W}, Look) ->
    Row = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Row, "margin:6px 0;font:14px monospace"),
    Label = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Label, "display:inline-block;width:110px;color:#ccc"),
    wse:appendChild(Ws, Label, wse:createTextNode(Ws, maps:get(label, Look))),
    %% The label is the signal, to mark for the model view (csp_code).
    wse:set(Ws, Label, "id", "sl_" ++ Name),
    wse:cast(Ws, Label, "setAttribute", ["data-sig", Name]),
    wse:appendChild(Ws, Row, Label),
    Node = case Kind of
	       toggle  -> switch(Ws, Row, Name, Look);
	       push    -> push(Ws, Row, Name, Look);
	       lamp    -> lamp(Ws, Row, Look);
	       action  -> action(Ws, Row, Look);
	       slider  -> slider(Ws, Row, Name, Look);
	       dial    -> dial(Ws, Row, Name, Look);
	       invalue -> invalue(Ws, Row, Name, Look);
	       meter   -> meter(Ws, Row, Look);
	       value   -> value_out(Ws, Row, Look)
	   end,
    wse:appendChild(Ws, Root, Row),
    Node.

%% An input's value has to travel with the name, so the notify carries
%% "Name=Value" and the loop splits on the first '='. A switch sends the bare
%% name, which is how the two are told apart.
%% The range is the look's min..max: a signed channel goes below zero, and a
%% narrowed one gives the whole travel to the part that matters.
slider(Ws, Row, Name, Look = #{min := Min, max := Max, colour := {On, _}}) ->
    S = wse:createElement(Ws, "input"),
    wse:set(Ws, S, "type", "range"),
    wse:set(Ws, S, "min", n(Min)),
    wse:set(Ws, S, "max", n(Max)),
    wse:set(Ws, S, "value", n(min(max(0, Min), Max))),
    style(Ws, S, ["width:200px;vertical-align:middle;accent-color:", On]),
    {ok, Id} = wse:create_event(Ws),
    Func = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			", '" ++ Name ++ "=' + this.value); }"),
    wse:set(Ws, S, "oninput", Func),
    wse:appendChild(Ws, Row, S),
    Out = readout(Ws, Row),
    {slider, S, Out, Look}.

%% Held down rather than latched: mousedown sends the pressed level, mouseup
%% the resting one -- 1 and 0, or 0 and 1 for a button to ground (pullup).
%% Reuses the slider wire format (Name=Value) rather than inventing a second.
push(Ws, Row, Name, Look = #{colour := Hue}) ->
    Idle = maps:get(idle, Look, 0),
    B = wse:createElement(Ws, "button"),
    wse:setStyle(Ws, B, "width:60px;padding:4px;font:14px monospace;"
		 "background:#333;color:#eee;border:1px solid #555"),
    wse:appendChild(Ws, B, wse:createTextNode(Ws, integer_to_list(Idle))),
    {ok, Id} = wse:create_event(Ws),
    Down = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			", '" ++ Name ++ "=" ++ integer_to_list(1 - Idle) ++
			"'); }"),
    Up = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
		      ", '" ++ Name ++ "=" ++ integer_to_list(Idle) ++ "'); }"),
    wse:set(Ws, B, "onmousedown", Down),
    wse:set(Ws, B, "onmouseup", Up),
    wse:set(Ws, B, "onmouseleave", Up),     % dragging off must not leave it held
    wse:appendChild(Ws, Row, B),
    {switch, B, Hue, Idle}.

%% Something that DOES rather than indicates: a siren, a motor, a valve. Shown as
%% text that lights up, because a 18px dot does not say "the pump is running".
action(Ws, Row, #{colour := Hue}) ->
    A = wse:createElement(Ws, "span"),
    style(Ws, A, action_style(0, Hue)),
    wse:appendChild(Ws, A, wse:createTextNode(Ws, "off")),
    wse:appendChild(Ws, Row, A),
    {action, A, Hue}.

action_style(V, {On, Off}) ->
    ["display:inline-block;min-width:54px;text-align:center;padding:3px 8px;"
     "border-radius:3px;font:12px monospace;border:1px solid #555;",
     case V of
	 0 -> ["background:", Off, ";color:#777"];
	 _ -> ["background:", On, ";color:#111;font-weight:bold"]
     end].

%% A dial is a slider for the hand and a needle for the eye: the same range
%% input, plus a rotating pointer that reads at a glance.
dial(Ws, Row, Name, Look) ->
    Face = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Face, "display:inline-block;width:38px;height:38px;"
		 "border-radius:19px;border:2px solid #555;background:#252525;"
		 "position:relative;vertical-align:middle;margin-right:8px"),
    Needle = wse:createElement(Ws, "span"),
    style(Ws, Needle, needle_style(maps:get(min, Look), Look)),
    wse:appendChild(Ws, Face, Needle),
    wse:appendChild(Ws, Row, Face),
    {slider, S, Out, Look} = slider(Ws, Row, Name, Look),
    {dial, Needle, S, Out, Look}.

%% -135..+135 degrees, the usual instrument sweep, over min..max.
needle_style(V, Look = #{colour := {On, _}}) ->
    Deg = -135 + trunc(270 * candid:frac(V, Look)),
    ["position:absolute;left:50%;top:50%;width:2px;height:15px;"
     "background:", On, ";transform-origin:50% 100%;"
     "transform:translate(-50%,-100%) rotate(", integer_to_list(Deg), "deg)"].

%% An editable field, for an input whose value is a number rather than a level.
invalue(Ws, Row, Name, #{colour := {On, _}}) ->
    I = wse:createElement(Ws, "input"),
    wse:set(Ws, I, "type", "text"),
    wse:set(Ws, I, "size", 8),
    style(Ws, I, ["font:13px monospace;background:#222;color:", On, ";"
		  "border:1px solid #555;padding:2px 4px"]),
    {ok, Id} = wse:create_event(Ws),
    %% on Enter, not on every keystroke: half a number is not a value
    Func = wse:newf(Ws, "e", "{ if (e && e.key == 'Enter') Wse.notify(" ++
			integer_to_list(Id) ++ ", '" ++ Name ++
			"=' + this.value); }"),
    wse:set(Ws, I, "onkeydown", Func),
    wse:appendChild(Ws, Row, I),
    {invalue, I}.

%% Just the number, for an output nobody wants a bar for.
value_out(Ws, Row, Look = #{colour := {On, _}}) ->
    T = wse:createElement(Ws, "span"),
    style(Ws, T, ["font:14px monospace;color:", On, ";min-width:60px;"
		  "display:inline-block"]),
    wse:appendChild(Ws, T, wse:createTextNode(Ws, "0")),
    wse:appendChild(Ws, Row, T),
    {value, T, Look}.

meter(Ws, Row, Look = #{colour := {On, _}}) ->
    Outer = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Outer, "display:inline-block;width:200px;height:12px;"
		 "background:#252525;border:1px solid #555;vertical-align:middle"),
    Bar = wse:createElement(Ws, "span"),
    style(Ws, Bar, ["display:block;height:100%;width:0;background:", On]),
    wse:appendChild(Ws, Outer, Bar),
    wse:appendChild(Ws, Row, Outer),
    Out = readout(Ws, Row),
    {meter, Bar, Out, Look}.

%% Every port 9 pixel side by side on one line. That is what the strip is on
%% the board, and one swatch per row neither looks like the hardware nor lets
%% you see a pattern travel along it -- which is the whole of what cpx_ball
%% does.
strip(_Ws, _Root, []) -> [];
strip(Ws, Root, Pixels) ->
    Row = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Row, "margin:12px 0;font:14px monospace"),
    Label = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Label, "display:inline-block;width:110px;color:#ccc"),
    wse:appendChild(Ws, Label, wse:createTextNode(Ws, "port 9")),
    wse:appendChild(Ws, Row, Label),
    Nodes = [{Name, cell(Ws, Row, maps:get(label, Look))}
	     || {Name, Look} <- Pixels],
    wse:appendChild(Ws, Root, Row),
    Nodes.

cell(Ws, Row, Label) ->
    C = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, C, ?PIXEL "background:#000"),
    wse:set(Ws, C, "title", Label),     % hover says which pixel
    wse:appendChild(Ws, Row, C),
    {pixel, C}.

%%% One canvas per group, and ONE painter function shared by all of them -- the
%%% browser compiles it once, exactly as painter/1 does for the trace.
plot_panels(_Ws, _Root, []) ->
    {[], []};
plot_panels(Ws, Root, Groups) ->
    Plot = plotter(Ws),
    lists:foldl(fun(G, {Gs, Ns}) ->
			{G1, N1} = plot_panel(Ws, Root, G, Plot),
			{Gs ++ [G1], Ns ++ N1}
		end, {[], []}, Groups).

plot_panel(Ws, Root, G = #{id := Id, x := X, ys := Ys}, Plot) ->
    Box = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Box, "margin:12px 0;font:14px monospace"),
    Label = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Label, "display:inline-block;width:110px;color:#ccc;"
		 "vertical-align:top"),
    wse:appendChild(Ws, Label, wse:createTextNode(Ws, Id)),
    wse:appendChild(Ws, Box, Label),
    C = wse:createElement(Ws, "canvas"),
    wse:set(Ws, C, "width", ?PLOT_W),
    wse:set(Ws, C, "height", ?PLOT_W),
    wse:setStyle(Ws, C, [?GLASS, css(?PLOT_BG), ";",
			 case maps:get(round, G) of
			     true  -> ?ROUND;
			     false -> ?FLAT
			 end]),
    wse:appendChild(Ws, Box, C),
    {ok, Ctx} = wse:call(Ws, C, "getContext", ["2d"]),
    Side = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Side, "display:inline-block;margin-left:12px;"
		 "vertical-align:top"),
    Members = [{"x", M} || M <- [X], M =/= undefined] ++
	[{"y", M} || M <- Ys],
    Nodes = [{maps:get(name, M), {plotval, plot_row(Ws, Side, Ax, M), M}}
	     || {Ax, M} <- Members],
    wse:appendChild(Ws, Box, Side),
    wse:appendChild(Ws, Root, Box),
    xy_handler(Ws, C, candid:drivable(X, Ys)),
    {G#{ctx => Ctx, plot => Plot}, Nodes}.

%% axis, name, and the live value beside it -- in engineering units when the
%% annotation gave enough to work them out.
plot_row(Ws, Side, Axis, M) ->
    Row = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Row, "margin-bottom:4px"),
    Tag = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Tag, ["color:", maps:get(colour, M),
			   ";font:12px monospace"]),
    wse:appendChild(Ws, Tag, wse:createTextNode(
				Ws, Axis ++ "  " ++ maps:get(label, M))),
    wse:appendChild(Ws, Row, Tag),
    V = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, V, "display:block;color:#888;font:12px monospace"),
    wse:appendChild(Ws, V, wse:createTextNode(Ws, "")),
    wse:appendChild(Ws, Row, V),
    wse:appendChild(Ws, Side, Row),
    V.


%%% THE CANVAS IS THE CONTROL: the pointer is the beam, which is what makes an
%%% XY pair worth steering by hand -- two sliders cannot be moved together.
%%%
%%% Both axes go as two separate notifies of "Name=Value", the same wire format
%%% a slider uses. Inventing a two-value message for this would mean the panel
%%% could say something you cannot type at the csp prompt, and that is the one
%%% property that makes it debuggable.
%%%
%%% In run mode the values land and the next tick commits them. Under /pause
%%% they wait and ONE /step commits both -- the instant a board would see, with
%%% x and y belonging to the same cycle.
xy_handler(_Ws, _C, []) ->
    ok;
xy_handler(Ws, C, Sends) ->
    {ok, Id} = wse:create_event(Ws),
    Body = ["{ var r = this.getBoundingClientRect(); ",
	    [send_js(Id, Ax, M) || {Ax, M} <- Sends], " }"],
    %% Held, not hovered: a plot you cannot take your hand off is a plot you
    %% cannot click anything else beside.
    Move = wse:newf(Ws, "e", lists:flatten(["{ if (this.__xy) ", Body, " }"])),
    Down = wse:newf(Ws, "e", lists:flatten(["{ this.__xy = 1; ", Body, " }"])),
    Up = wse:newf(Ws, "e", "{ this.__xy = 0; }"),
    wse:set(Ws, C, "onmousedown", Down),
    wse:set(Ws, C, "onmousemove", Move),
    wse:set(Ws, C, "onmouseup", Up),
    wse:set(Ws, C, "onmouseleave", Up),
    ok.

%% The pointer's position as a fraction of the box, mapped onto the channel's
%% own range -- min..max, not 0..full-scale, so a narrowed plot drives the same
%% values it displays. Up is UP: the top of the box is max, as on a scope and
%% unlike a canvas coordinate.
send_js(Id, Axis, M) ->
    Min = maps:get(min, M),
    Max = maps:get(max, M),
    {Frac, V} = case Axis of
		    across -> {"(e.clientX - r.left) / (r.width || 1)", "vx"};
		    up     -> {"(1 - (e.clientY - r.top) / (r.height || 1))",
			       "vy"}
		end,
    %% One variable per axis: both axes are sent from the same function, and a
    %% second `var v' in it is a redeclaration that reads as a bug even where
    %% the language allows it.
    ["var ", V, " = ", n(Min), " + Math.round(", Frac, " * ", n(Max - Min),
     "); ",
     V, " = ", V, " < ", n(Min), " ? ", n(Min), " : (", V, " > ", n(Max),
     " ? ", n(Max), " : ", V, "); ",
     "Wse.notify(", integer_to_list(Id), ", '", maps:get(name, M),
     "=' + ", V, "); "].

n(V) when is_integer(V) -> integer_to_list(V);
n(V) when is_float(V)   -> lists:flatten(io_lib:format("~w", [trunc(V)])).

css({R, G, B}) ->
    lists:flatten(io_lib:format("rgb(~w,~w,~w)", [R, G, B])).

%%% The afterglow. One cast per plot per tick: every pixel decays toward the
%%% background, then the graticule, then the beam.
%%%
%%% The decay is what a phosphor does -- everything already drawn gets a little
%%% dimmer, so the beam leaves a trail that fades instead of a line that stays.
%%%
%%% It is done PER PIXEL, on the image data, and not as a translucent wash of
%%% the background over the canvas. A wash never gets there: each channel moves
%%% by round(a * distance), and once a * distance is under a half the rounding
%%% eats the step and the pixel stops for good -- at a = 0.1 that is five levels
%%% short of the background, which is the ghost a trail left behind. Here the
%%% distance is multiplied and TRUNCATED, so it shrinks by at least one level
%%% every tick and every trail reaches the background exactly.
%%%
%%% The graticule is redrawn after the decay, every tick, so it does not fade
%%% with the trail: a scope's screen is printed, not drawn.
plotter(Ws) ->
    {R, G, B} = ?PLOT_BG,
    Bg = lists:flatten(io_lib:format("~w,~w,~w", [R, G, B])),
    %% Ten numbers in, five per channel after them: where the beam WAS, where
    %% it is now, and the colour. The segment is what turns ten samples a second
    %% into a curve rather than ten dots.
    %%
    %% x0 < 0 means NO segment: the first sample after a rebuild, and a retrace
    %% (see seg/2).
    %%
    %% `step' draws across at the OLD height and then up: the value held until
    %% the next sample, which is what a square wave is. `dot' is the head's
    %% radius, 0 for none. `glow' blooms the head (shadowBlur) -- the trail
    %% never does, bloom on a stroke is the expensive one -- and is turned off
    %% again straight after, or the next graticule would glow too.
    %%
    %% An odd line width is drawn on the half pixel, so a thin line is one sharp
    %% pixel wide instead of two half-lit ones.
    %%
    %% The CLIP is a path, not a trust: border-radius does clip a canvas in the
    %% browsers that matter, but nothing in the drawing says so. With it on,
    %% the decay and the graticule stop at the glass too -- pixels outside it
    %% are never painted, stay transparent, and are skipped by the decay.
    wse:newf(Ws, "ctx,w,h,keep,round,clip,beam,dot,glow,step,a",
	     "{ var bg = [" ++ Bg ++ "];"
	     "  if (!ctx.__lit) { ctx.__lit = 1;"
	     "    ctx.save();"
	     "    if (clip) { ctx.beginPath();"
	     "      ctx.arc(w / 2, h / 2, Math.min(w, h) / 2 - 1, 0, 6.2832);"
	     "      ctx.clip(); }"
	     "    ctx.fillStyle = 'rgb(' + bg + ')'; ctx.fillRect(0, 0, w, h);"
	     "    ctx.restore(); }"
	     "  if (ctx.__keep !== keep) { ctx.__keep = keep;"
	     "    ctx.__lut = new Uint8Array(256);"
	     "    for (var j = 0; j < 256; j++)"
	     "      ctx.__lut[j] = Math.floor(j * keep); }"
	     "  var L = ctx.__lut, im = ctx.getImageData(0, 0, w, h), d = im.data;"
	     "  for (var p = 0; p < d.length; p += 4) {"
	     "    if (d[p+3] === 0) continue;"
	     "    for (var c = 0; c < 3; c++) {"
	     "      var v = d[p+c], b = bg[c];"
	     "      d[p+c] = v >= b ? b + L[v - b] : b - L[b - v]; } }"
	     "  ctx.putImageData(im, 0, 0);"
	     "  if (clip) { ctx.save(); ctx.beginPath();"
	     "    ctx.arc(w / 2, h / 2, Math.min(w, h) / 2 - 1, 0, 6.2832);"
	     "    ctx.clip(); }"
	     "  ctx.strokeStyle = '#203420'; ctx.lineWidth = 1;"
	     "  if (round) {"
	     "    var cx = w / 2, cy = h / 2, r = Math.min(w, h) / 2 - 2;"
	     "    for (var g = 1; g <= 3; g++) {"
	     "      ctx.beginPath(); ctx.arc(cx, cy, r * g / 3, 0, 6.2832);"
	     "      ctx.stroke(); }"
	     "    ctx.beginPath();"
	     "    ctx.moveTo(cx - r, cy); ctx.lineTo(cx + r, cy);"
	     "    ctx.moveTo(cx, cy - r); ctx.lineTo(cx, cy + r);"
	     "    ctx.stroke(); }"
	     "  else {"
	     "    ctx.beginPath();"
	     "    for (var k = 1; k < 4; k++) {"
	     "      var q = Math.round(k * w / 4) + 0.5;"
	     "      ctx.moveTo(q, 0); ctx.lineTo(q, h);"
	     "      var s = Math.round(k * h / 4) + 0.5;"
	     "      ctx.moveTo(0, s); ctx.lineTo(w, s); }"
	     "    ctx.stroke(); }"
	     "  var o = (Math.round(beam) % 2) ? 0.5 : 0;"
	     "  ctx.lineWidth = beam;"
	     "  ctx.lineCap = glow ? 'round' : 'square';"
	     "  ctx.lineJoin = glow ? 'round' : 'miter';"
	     "  for (var i = 0; i < a.length; i += 5) {"
	     "    var col = a[i+4], x0 = a[i] + o, y0 = a[i+1] + o,"
	     "        x1 = a[i+2] + o, y1 = a[i+3] + o;"
	     "    if (a[i] >= 0 && beam > 0) {"
	     "      ctx.strokeStyle = col;"
	     "      ctx.beginPath(); ctx.moveTo(x0, y0);"
	     "      if (step) ctx.lineTo(x1, y0);"
	     "      ctx.lineTo(x1, y1); ctx.stroke(); }"
	     "    if (dot > 0) {"
	     "      ctx.fillStyle = col;"
	     "      if (glow) { ctx.shadowColor = col; ctx.shadowBlur = 7; }"
	     "      ctx.beginPath(); ctx.arc(x1, y1, dot, 0, 6.2832);"
	     "      ctx.fill(); ctx.shadowBlur = 0; } }"
	     "  if (clip) ctx.restore(); }").

readout(Ws, Row) ->
    T = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, T, "margin-left:10px;color:#888;font:12px monospace"),
    wse:appendChild(Ws, T, wse:createTextNode(Ws, "")),
    wse:appendChild(Ws, Row, T),
    T.

switch(Ws, Row, Name, Look = #{colour := Hue}) ->
    Idle = maps:get(idle, Look, 0),
    B = wse:createElement(Ws, "button"),
    wse:setStyle(Ws, B, "width:60px;padding:4px;font:14px monospace;"
		 "background:#333;color:#eee;border:1px solid #555"),
    wse:appendChild(Ws, B, wse:createTextNode(Ws, integer_to_list(Idle))),
    {ok, Id} = wse:create_event(Ws),
    Func = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			",'" ++ Name ++ "'); }"),
    wse:set(Ws, B, "onclick", Func),
    wse:appendChild(Ws, Row, B),
    {switch, B, Hue, Idle}.

lamp(Ws, Row, #{colour := Hue}) ->
    L = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, L, ?LAMP ?LAMP_OFF),
    wse:appendChild(Ws, Row, L),
    {lamp, L, Hue}.

%% No rows, no canvas: the core then only moves the plots.
canvas(_Ws, _Root, []) ->
    none;
canvas(Ws, Root, Looks) ->
    C = wse:createElement(Ws, "canvas"),
    wse:set(Ws, C, "width", ?GUTTER + ?TRACE_W),
    wse:set(Ws, C, "height", length(Looks) * ?ROW_H + 8),
    wse:setStyle(Ws, C, "margin-top:14px;background:#1a1a1a;"
		 "border:1px solid #333"),
    wse:appendChild(Ws, Root, C),
    {ok, Ctx} = wse:call(Ws, C, "getContext", ["2d"]),
    labels(Ws, Ctx, Looks),
    {Ctx, painter(Ws)}.

%% The names down the left, once: a trace of eight stripes is unreadable when
%% you have to count rows against the widgets above to know which is which.
%% Each in its signal's colour, which is also the colour of its line. The
%% gutter is never cleared -- draw/2 wraps the trace to the right of it.
labels(Ws, Ctx, Looks) ->
    Items = lists:append(
	      [[short(maps:get(label, L)), I * ?ROW_H + 4 + (?ROW_H - 12) div 2,
		element(1, maps:get(colour, L))]
	       || {I, L} <- lists:zip(lists:seq(0, length(Looks) - 1), Looks)]),
    F = wse:newf(Ws, "ctx,gw,a",
		 "{ ctx.font = '12px monospace'; ctx.textBaseline = 'middle';"
		 "  for (var i = 0; i < a.length; i += 3) {"
		 "    ctx.fillStyle = a[i+2]; ctx.fillText(a[i], 6, a[i+1]); }"
		 "  ctx.fillStyle = '#333'; ctx.fillRect(gw - 4, 0, 1, 4096); }"),
    wse:cast(Ws, F, "call", [null, Ctx, ?GUTTER, wse:array(Items)]).

%% What fits in the gutter at 12px monospace, with an ellipsis when it does not.
short(S) when length(S) =< 13 -> S;
short(S)                      -> lists:sublist(S, 12) ++ "~".

%%% ONE asynchronous call per tick instead of two synchronous ones per trace.
%%%
%%% wse:set/4 and wse:setStyle/3 are rsync -- they wait for the browser to
%%% answer. Drawing a column as `set(fillStyle)' plus `cast(fillRect)' per trace
%%% therefore cost one ROUND TRIP per trace per tick: measured at 342 synchronous
%%% calls a second with 31 widgets at 10 Hz, each one blocking this process.
%%%
%%% This is a function created once in the browser that takes the whole column
%%% as a flat list -- x, y, colour, x, y, colour -- and is invoked with cast,
%%% which does not wait. Flat rather than nested because wse encodes a list of
%%% lists as a JSON array of arrays and the marshalling is what we are trying to
%%% avoid.
painter(Ws) ->
    wse:newf(Ws, "ctx,a",
	     "{ for (var i = 0; i < a.length; i += 3) {"
	     "    ctx.fillStyle = a[i+2];"
	     "    ctx.fillRect(a[i], a[i+1], " ++ integer_to_list(?STEP) ++
	     ", 3); } }").

%%% ------------------------------------------------------------ painting

paint1(Ws, {ok, {lamp, Node, {On, Off}}}, V) ->
    style(Ws, Node,
	  case V of
	      0 -> [?LAMP, "background:", Off];
	      _ -> [?LAMP, "background:", On, ";box-shadow:0 0 9px ", On]
	  end);
%% A switch away from rest shows it in its colour, so a pressed button reads
%% as pressed without having to read the digit on it -- a button to ground is
%% pressed at 0.
paint1(Ws, {ok, {switch, Node, {On, _Off}, Idle}}, V) ->
    style(Ws, Node, ["width:60px;padding:4px;font:14px monospace;"
		     "border:1px solid #555;",
		     case V =:= Idle of
			 true -> "background:#333;color:#eee";
			 false -> ["background:", On, ";color:#111;font-weight:bold"]
		     end]),
    wse:set(Ws, Node, "textContent", label(V));
paint1(Ws, {ok, {meter, Bar, Out, Look = #{colour := {On, _}}}}, V) ->
    Pct = trunc(100 * candid:frac(V, Look)),
    style(Ws, Bar, io_lib:format("display:block;height:100%;"
				 "background:~s;width:~w%", [On, Pct])),
    wse:set(Ws, Out, "textContent", lists:flatten(candid:eng(V, Look)));
paint1(Ws, {ok, {action, Node, Hue}}, V) ->
    style(Ws, Node, action_style(V, Hue)),
    wse:set(Ws, Node, "textContent", case V of 0 -> "off"; _ -> "ON" end);
paint1(Ws, {ok, {dial, Needle, _S, Out, Look}}, V) ->
    style(Ws, Needle, needle_style(V, Look)),
    wse:set(Ws, Out, "textContent", lists:flatten(candid:eng(V, Look)));
paint1(Ws, {ok, {value, Node, Look}}, V) ->
    wse:set(Ws, Node, "textContent", lists:flatten(candid:eng(V, Look)));
%% An input's field is left alone while it is being typed in, same reasoning as
%% the slider: csp owning it would fight the hand.
paint1(_Ws, {ok, {invalue, _Node}}, _V) ->
    ok;
%% A plot channel's number, in engineering units when the annotation gave enough
%% to work them out. The beam is drawn on the tick, not here.
paint1(Ws, {ok, {plotval, Node, M}}, V) ->
    wse:set(Ws, Node, "textContent", lists:flatten(candid:eng(V, M)));
paint1(Ws, {ok, {pixel, Node}}, V) ->
    style(Ws, Node, [?PIXEL, "background:", candid:rgb565(V)]);
%% A slider is an INPUT: csp owning the value would fight the drag, so only the
%% readout follows. The control itself is left where the hand put it.
paint1(Ws, {ok, {slider, _S, Out, Look}}, V) ->
    wse:set(Ws, Out, "textContent", lists:flatten(candid:eng(V, Look)));
paint1(_Ws, _, _V) ->
    ok.

label(0) -> "0";
label(_) -> "1".

%% wse encodes a plain Erlang list as a JSON ARRAY, and only a flat string as a
%% string -- so an iolist handed to setStyle arrives as [["..."],["..."]] and the
%% style is silently dropped. Everything built up from pieces goes through here.
style(Ws, Node, IoList) ->
    wse:setStyle(Ws, Node, lists:flatten(IoList)).

text(Ws, Root, Str) ->
    P = wse:createElement(Ws, "pre"),
    wse:setStyle(Ws, P, "color:#e77;font:13px monospace"),
    wse:appendChild(Ws, P, wse:createTextNode(Ws, lists:flatten(Str))),
    wse:appendChild(Ws, Root, P).

%% wse's priv/, taken from where its beam actually is, so the aliased scripts
%% are always the ones belonging to the wse serving the websocket.
wse_priv() ->
    filename:join(filename:dirname(
		    filename:dirname(filename:absname(code:which(wse)))),
		  "priv").

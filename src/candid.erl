%%% The smallest complete loop: a switch, a lamp, and a trace.
%%%
%%% The panel is DERIVED, not configured. candyspeak:parse/1 gives the
%%% declarations, and the direction in them decides the widget: `digital in`
%%% is something you press, `digital out` is something that lights up. Add a
%%% declaration to the .csp file and the widget appears -- there is no second
%%% file to keep in step.
%%%
%%% Everything the panel sends is a line a human could type at the csp prompt
%%% ("> Button = 1"), which is what makes it debuggable: when the panel does
%%% something surprising, type the same line yourself and see who is wrong.

-module(candid).

-export([start/0, start/2]).
-export([run/2, run/3]).
-export([widgets/1, rgb565/1, hue/1, label_of/1]).   % tests, introspection
-export([plots/1, eng/2, period/0, keep/2]).         % tests, introspection
-export([looks/1, colour/3]).                        % tests, introspection

-define(PERIOD,    100).   % ms between cycles -- the DEFAULT, see period/0
%% What the tick rate may be set to, from the bar. 100 ms was chosen for lamps;
%% a plot wants a good deal more than ten samples a second, and a program with
%% a 2 s sweep gives twenty points at 100 ms. The top of the range is honest
%% about what it costs: every tick is a /commit plus one cast per plot.
-define(PERIODS,   [10, 25, 50, 100, 250]).
-define(TRACE_BOX, "flex:none;max-height:35vh;overflow:auto;").  % at the bottom
-define(TRACE_W,   720).   % trace width, px, right of the labels
-define(GUTTER,    110).   % px of labels at the left of the trace -- the
			   % same width as a row's label, so they line up
-define(ROW_H,      34).   % px per trace row
-define(STEP,        3).   % px per sample
-define(LAMP,     "display:inline-block;width:18px;height:18px;"
		  "border-radius:9px;border:1px solid #555;").
-define(PIXEL,    "display:inline-block;width:22px;height:22px;"
		  "border:1px solid #444;margin-right:2px;"
		  "vertical-align:middle;").
-define(LAMP_ON,  "background:#3f3;box-shadow:0 0 8px #3f3").
-define(LAMP_OFF, "background:#252525").
%% The XY plot. SQUARE, because an XY picture is only honest when both axes
%% are the same length -- a circle in a wide box is an ellipse, and you cannot
%% tell which it was. Dark green because the afterglow is a phosphor.
-define(PLOT_W,   240).            % px, square
-define(PLOT_BG,  {16, 20, 16}).
-define(PAD,        4).            % inset, so a full-scale dot is a whole dot
-define(PHOSPHOR, "#5f9").  % the beam, when the annotation names no colour
%% The glass. `shape=round' is a CRT face: the corners of the value range fall
%% outside it, which is a choice and not a bug -- a channel at both extremes at
%% once is off the glass. shape=square keeps all of it, and is the default for
%% that reason.
-define(GLASS,    "vertical-align:top;cursor:crosshair;background:").
-define(FLAT,     "border:1px solid #333;").
-define(ROUND,    "border-radius:50%;border:3px solid #2b2b2b;"
		  "box-shadow:0 0 0 4px #141414,"
		  "0 0 18px rgba(90,255,160,0.13);").
-define(PERSIST,  0.90).           % how much of the last frame survives 100 ms
-define(BEAM_W,   1.6).            % px, line width of the beam
%% The kinds that show a number, and so take unit, scale, min and max.
-define(IS_NUMERIC(K), (K =:= slider orelse K =:= dial orelse K =:= invalue
			orelse K =:= meter orelse K =:= value
			orelse K =:= plot orelse K =:= plotin)).

%%% --------------------------------------------------------------- starting
%%%
%%% wse_server speaks websocket on /websession and NOTHING else -- a plain GET
%%% for the page falls out of its handshake with a case_clause. So the page needs
%%% an ordinary web server: inets serves priv/ for panel.html, and ALIASES
%%% wse's own priv/ at /js for ej.js and wse.js. Copying those two in would
%%% work and is what one usually does, but then they silently diverge from the
%%% wse that is actually serving the websocket.

start() -> start(1234, 8080).

start(WsPort, HttpPort) ->
    ok = ensure_inets(),
    {ok, _} = inets:start(httpd,
			  [{port, HttpPort},
			   {server_name, "candid"},
			   {server_root, priv_dir()},
			   {document_root, priv_dir()},
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

%% The tick the panel starts at. Settable from the bar while it runs; the
%% environment is for starting it somewhere other than the default, the way
%% CSP_EXE and CANDID_DEMO work.
period() ->
    case os:getenv("CANDID_PERIOD") of
	false -> ?PERIOD;
	S     -> case string:to_integer(S) of
		     {N, _} when is_integer(N), N >= 5, N =< 10000 -> N;
		     _ ->
			 io:format("panel: CANDID_PERIOD=~s is not a number "
				   "of ms between 5 and 10000~n", [S]),
			 ?PERIOD
		 end
    end.

%%% -------------------------------------------------------------------- entry

run(Ws, Where) ->
    run(Ws, Where, default_file()).

run(Ws, Where, File) ->
    %% The chat, when ellm is there: its own process, so it lives through
    %% every rebuild below.
    Chat = csp_chat:start(Ws, #{root => root(), exe => csp_exe(),
				demo_dir => demo_dir()}),
    render(Ws, Where, File, Chat).

%% Also the restart path: picking another file in the chooser comes back here,
%% so the whole panel is rebuilt from that file's declarations.
render(Ws, Where, File, Chat) ->
    Root = wse:id(Where),
    wse:set(Ws, Root, "innerHTML", ""),
    case candyspeak:parse(File) of
	{ok, Ast} ->
	    build(Ws, Where, Root, File, widgets(Ast), Ast, Chat);
	Error ->
	    chooser(Ws, Root, File, Chat),
	    text(Ws, Root, io_lib:format("~n~p cannot be parsed: ~p",
					 [File, Error]))
    end.

%%% ------------------------------------------------------------------ widgets

%% The whole derivation. A declaration's direction gives the widget, and an
%% `#annotate panel <target> kind=...' overrides it -- presentation is not in the
%% language and must not be, so it is said next to the declaration instead.
%%
%% A declaration inside a #module is a widget PER OBJECT, named as csp dumps it:
%% cpx_m.csp's `#analog P out 9:0' in Pixel is ten pixels p0.P .. p9.P. Taken
%% from the template it was one pixel called P that nothing ever wrote.
widgets(Ast) ->
    Ann = annotations(Ast),
    {Main, Mods} = csp_code:split(Ast),
    Decls = fun(Ds) ->
		    Bufs = buffers(Ds),
		    lists:foldr(fun(D, Acc) -> collect(D, Acc, Bufs) end, [], Ds)
	    end,
    Objs = [{K, O ++ "." ++ N, W}
	    || {object, _, {'WORD', _, M}, {'WORD', _, O}, _} <- Main,
	       {ok, Body} <- [maps:find(M, Mods)],
	       {K, N, W} <- Decls(Body)],
    [apply_ann(W, Ann) || W <- Decls(Main) ++ Objs].

%% Which buffer each #field looks into, and what that buffer is: its direction,
%% and whether anything is wired to it. A field cannot be read from its own
%% declaration alone -- see widget/2.
buffers(Ast) ->
    lists:foldl(
      fun({buffer, _Ln, {'WORD', _, N}, _Sz, Opts, Trans}, M) ->
	      M#{N => {proplists:get_value(dir, Opts, out), Trans =/= []}};
	 (_, M) -> M
      end, #{}, Ast).

%% #annotate panel <target> key=value ... -> #{Target => #{Key => Value}}
%% Only rows naming THIS tool. The keys are ours to validate: an unknown one is
%% warned about rather than ignored, because a layout that silently drops a typo
%% is how it stops matching the program.
annotations(Ast) ->
    lists:foldl(
      fun({annotate, Ln, {'WORD', _, "panel"}, {'WORD', _, Target}, Items}, M) ->
	      Kv = maps:from_list([{K, ann_value(V)}
				   || {{'WORD', _, K}, V} <- Items]),
	      warn_unknown(Target, Kv, Ln),
	      warn_star(Target, Kv, Ln),
	      maps:put(Target, maps:merge(maps:get(Target, M, #{}), Kv), M);
	 (_, M) -> M
      end, #{}, Ast).

ann_value(true)              -> true;
ann_value({'WORD', _, V})    -> V;
ann_value({'INT', _, V})     -> V;
ann_value({'FLT', _, V})     -> V;
ann_value({'STR', _, V})     -> V;
ann_value(V)                 -> V.

-define(ANN_KEYS, ["kind", "label", "hidden", "color",
		   %% what a count means and how far it swings -- any widget that
		   %% shows a number. See the look section below.
		   "unit", "scale", "min", "max",
		   %% a plot reads these: which picture, which way, and what a
		   %% count means in the world. See the plots section below.
		   "axis", "id", "persist", "shape", "clip",
		   %% how the beam is drawn
		   "beam", "dot", "glow", "line",
		   %% a row in the logic trace, or on `*' the whole trace
		   "trace"]).

%% Keys that are about ONE signal: said on `*' they would make every widget
%% the same kind, or give them all one label. Never inherited from `*'.
-define(OWN_KEYS, ["kind", "label", "axis"]).

warn_unknown(Target, Kv, Ln) ->
    case [K || K <- maps:keys(Kv), not lists:member(K, ?ANN_KEYS)] of
	[] -> ok;
	Ks -> io:format("panel: line ~w: ~s: unknown annotation key~s ~s~n"
			"       known: ~s~n",
			[Ln, Target, case Ks of [_] -> ""; _ -> "s" end,
			 string:join(Ks, ", "), string:join(?ANN_KEYS, ", ")])
    end.

%% `#annotate panel *' is the panel itself: `trace=off' there turns the whole
%% logic trace off, and any other key is a default for every widget it applies
%% to -- `* glow=off' for every plot, `* hidden' and then `hidden=0' on the few
%% that should show. A widget's own key wins. See kv/2.
warn_star("*", Kv, Ln) ->
    case [K || K <- maps:keys(Kv), lists:member(K, ?OWN_KEYS)] of
	[] -> ok;
	Ks -> io:format("panel: line ~w: *: ~s belongs to one signal, not the "
			"panel; ignored~n", [Ln, string:join(Ks, ", ")])
    end;
warn_star(_Target, _Kv, _Ln) ->
    ok.

%% `kind' may only move a widget WITHIN what the declaration allows: a digital in
%% can be a push or a toggle, not a dial. Asking for the impossible is a warning
%% and the derived kind stands -- the alternative is a panel that cannot drive
%% the pin it is wired to.
apply_ann({Kind, Name, W}, Ann) ->
    Kv = maps:get(Name, Ann, #{}),
    case maps:get("kind", Kv, undefined) of
	undefined -> {Kind, Name, W};
	Want ->
	    case allowed(Kind, Want) of
		{ok, K2} -> {K2, Name, W};
		no ->
		    io:format("panel: ~s: kind=~s is not one a ~w can be "
			      "(~s)~n", [Name, Want, Kind,
					 string:join(alternatives(Kind), ", ")]),
		    {Kind, Name, W}
	    end
    end.

allowed(toggle, "push")   -> {ok, push};
allowed(toggle, "toggle") -> {ok, toggle};
allowed(push, "toggle")   -> {ok, toggle};
allowed(push, "push")     -> {ok, push};
allowed(lamp, "action")   -> {ok, action};
allowed(lamp, "lamp")     -> {ok, lamp};
allowed(slider, "dial")   -> {ok, dial};
allowed(slider, "slider") -> {ok, slider};
allowed(slider, "value")  -> {ok, invalue};
allowed(meter, "value")   -> {ok, value};
allowed(meter, "meter")   -> {ok, meter};
%% A plot channel keeps its DIRECTION in the kind: the canvas is the control
%% for an input (the pointer is the beam), and a picture of the program for an
%% output. One kind for both would mean a canvas that cannot drive the pin it
%% is wired to -- the same mistake allowed/2 exists to prevent.
allowed(slider, "plot")   -> {ok, plotin};
allowed(meter, "plot")    -> {ok, plot};
allowed(pixel, "pixel")   -> {ok, pixel};
allowed(_Kind, _Want)     -> no.

alternatives(toggle) -> ["push", "toggle"];
alternatives(push)   -> ["push", "toggle"];
alternatives(lamp)   -> ["lamp", "action"];
alternatives(slider) -> ["slider", "dial", "value", "plot"];
alternatives(meter)  -> ["meter", "value", "plot"];
alternatives(pixel)  -> ["pixel"];
alternatives(_)      -> [].

collect(D, Acc, Bufs) ->
    case widget(D, Bufs) of
	skip               -> Acc;
	L when is_list(L)  -> L ++ Acc;      % an array: one widget per element
	W                  -> [W | Acc]
    end.

widget({digital, _Ln, {'WORD', _, Name}, scalar, _Res, Opts, _Expr}, _B) ->
    case proplists:get_value(dir, Opts) of
	in -> {toggle, Name, 1};
	_  -> {lamp, Name, 1}       % out, inout: show it
    end;
%% Analog carries its WIDTH in the resolution slot, so the control's range is
%% derived too -- a :10 in is a 0..1023 slider, a :16 out a full-scale meter.
%% PORT 9 is special: it is the CPX pixel strip, where the 16 bits are an
%% RGB565 colour rather than a magnitude. That mapping is an assumption about
%% the board, not something the declaration says, which is why it lives here
%% and not in widget/1's shape.
widget({analog, _Ln, {'WORD', _, Name}, scalar, Res, Opts, Expr}, _B) ->
    analog_widget(Name, width(Res), port_of(Expr),
		  proplists:get_value(dir, Opts));
%% An array: `#analog P[10]:16 out unsigned 9:0..9` is ten pixels, not one.
%% Returned as a LIST, which collect/2 splices -- cpx_rotate.csp declares its
%% strip this way and had no widgets at all until this clause existed.
widget({analog, _Ln, {'WORD', _, Name}, {array_size, _, Size}, Res, Opts,
	Expr}, _B) ->
    N = width(Size),
    W = width(Res),
    Port = port_of(Expr),
    Dir = proplists:get_value(dir, Opts),
    [analog_widget(Name ++ "[" ++ integer_to_list(I) ++ "]", W, Port, Dir)
     || I <- lists:seq(0, N - 1)];
%%% A #field is a WINDOW into a #buffer, and a buffer is bytes from somewhere --
%%% a CAN frame, a UDP datagram, a TCP stream. So a field reads as an analog
%%% channel of the width its window has, which is what makes a socket able to
%%% drive a plot.
%%%
%%% WHO OWNS THE VALUE decides whether the panel may touch it. A buffer with a
%%% transport is filled by that transport, and a panel writing over it would be
%%% fighting the wire -- the same reason a slider's own value is left alone while
%%% the hand is on it. A buffer with no endpoint has nobody else to fill it, so
%%% the panel does, exactly as it does for a host pin.
widget({field, _Ln, {'WORD', _, Name}, Res, _Opts, {'WORD', _, Buf}, Pos},
       Bufs) ->
    W = field_width(Res, Pos),
    case maps:get(Buf, Bufs, {out, false}) of
	{in, false} -> {slider, Name, W};
	_           -> {meter, Name, W}
    end;
widget(_, _B) ->
    skip.                           % variables, rules: not yet

%% The declared `:width' when there is one, else the window itself: [0..11] is
%% twelve bits, and a bare [9] is one.
field_width({'INT', _, S}, _Pos) ->
    list_to_integer(S);
field_width(_Default, {range, _, {'INT', _, Lo}, {'INT', _, Hi}}) ->
    list_to_integer(Hi) - list_to_integer(Lo) + 1;
field_width(_Default, {'INT', _, _Bit}) ->
    1;
field_width(_Default, _Pos) ->
    16.

analog_widget(Name, W, 9, _Dir)   -> {pixel, Name, W};
analog_widget(Name, W, _P, in)    -> {slider, Name, W};
analog_widget(Name, W, _P, _Dir)  -> {meter, Name, W}.

width({'INT', _, S}) -> list_to_integer(S);
width(_)             -> 16.         % `default` -- treat as full word

%% [{port_pin,_,Port,Pin}] or [{pin,_,Pin}]; only the port decides anything here
port_of([{port_pin, _, {'INT', _, P}, _Pin} | _]) -> list_to_integer(P);
port_of(_)                                        -> 0.

full(W) when W > 0, W < 32 -> (1 bsl W) - 1;
full(_)                    -> 65535.

%% RGB565 -> css. The strip is written as one 16 bit word per pixel.
rgb565(V) ->
    R = (V bsr 11) band 16#1f,
    G = (V bsr 5)  band 16#3f,
    B = V band 16#1f,
    lists:flatten(io_lib:format("rgb(~w,~w,~w)",
				[R * 255 div 31, G * 255 div 63,
				 B * 255 div 31])).

%%% ----------------------------------------------------------------- the look
%%%
%%% What an annotation says about how a widget LOOKS, the same for every kind:
%%% its label, whether it is shown, its colour, and -- for anything that shows
%%% a number -- what a count means (scale, unit) and how far it swings (min,
%%% max). `kind' is not here; it decides which widget, see apply_ann/2.
%%%
%%% One map per widget, so a lamp and a plot channel read `color=amber' the
%%% same way. Before this each kind read the keys it happened to know and the
%%% rest were dropped without a word -- `label' and `hidden' were accepted by
%%% the key check and then did nothing at all.
%%%
%%% Display only. csp always sees counts: a slider with scale=0.1 still sends
%%% the count, and the readout beside it says what that is in the world.

looks(Ast) ->
    looks(widgets(Ast), annotations(Ast), ranges(Ast)).

looks(Widgets, Ann, Rng) ->
    maps:from_list([{N, look(W, kv(N, Ann), Rng)} || W = {_, N, _} <- Widgets]).

look({Kind, Name, W}, Kv, Rng) ->
    {Lo, Hi} = maps:get(Name, Rng, {0, full(W)}),
    #{label  => ann_label(Name, Kv),
      hidden => onoff(Name, "hidden", Kv, false),
      trace  => onoff(Name, "trace", Kv, true),
      colour => colour(Name, Kind, Kv),
      %% The declared swing unless the annotation narrows it: a :10 channel
      %% that only ever moves 300..700 is a dot in the middle of the picture
      %% otherwise.
      min    => num(maps:get("min", Kv, Lo)),
      max    => num(maps:get("max", Kv, Hi)),
      scale  => num(maps:get("scale", Kv, 1)),
      unit   => utf8(maps:get("unit", Kv, ""))}.

%% A key the widget has no use for is SAID, not dropped: unit= on a lamp is a
%% mistake about what the lamp is, and a silent panel leaves you looking for
%% the number it was supposed to print.
warn_misplaced({Kind, Name, _W}, Ann) ->
    Kv = maps:get(Name, Ann, #{}),          % not `*': a default is not a mistake
    case [K || K <- maps:keys(Kv), not applies(K, Kind)] of
	[] -> ok;
	Ks -> io:format("panel: ~s: ~s means nothing on a ~w, ignored~n",
			[Name, string:join([K ++ "=" || K <- Ks], " "), Kind])
    end.

applies(K, Kind) when K =:= "unit"; K =:= "scale"; K =:= "min"; K =:= "max" ->
    numeric(Kind);
applies("color", Kind) -> Kind =/= pixel;    % a pixel's value IS its colour
applies(K, Kind) when K =:= "axis"; K =:= "id"; K =:= "persist";
		      K =:= "shape"; K =:= "clip"; K =:= "beam"; K =:= "dot";
		      K =:= "glow"; K =:= "line" ->
    is_plot({Kind, "", 0});
applies(_K, _Kind) -> true.

numeric(K) when ?IS_NUMERIC(K) -> true;
numeric(_K)                     -> false.

ann_label(Name, Kv) ->
    case maps:get("label", Kv, true) of
	true -> label_of(Name);
	L    -> utf8(to_text(L))
    end.

%% A yes/no key. `hidden' alone is hidden; hidden=0 is shown, which is what
%% makes it easy to bring one back without deleting the line.
onoff(Name, Key, Kv, Default) ->
    case maps:get(Key, Kv, Default) of
	B when is_boolean(B) -> B;
	V when V =:= "1"; V =:= "yes"; V =:= "true"; V =:= "on" -> true;
	V when V =:= "0"; V =:= "no"; V =:= "false"; V =:= "off" -> false;
	V -> io:format("panel: ~s: ~s=~s is neither on nor off~n",
		       [Name, Key, to_text(V)]),
	     Default
    end.

%% {On, Off}: the colour when lit and the dim one when not. Digital widgets
%% guess from the name when nothing is said (hue/1); a plot beam is phosphor --
%% the beam is what you watch, and `yin' is not yellow -- and anything else
%% that shows a level is the panel's blue.
colour(Name, Kind, Kv) ->
    case maps:get("color", Kv, none) of
	none -> default_colour(Kind, Name);
	C ->
	    case parse_colour(string:lowercase(to_text(C))) of
		{ok, Hue} -> Hue;
		none ->
		    io:format("panel: ~s: color=~s is not a colour name, "
			      "\"#rgb\", \"#rrggbb\" or 0xRRGGBB~n",
			      [Name, to_text(C)]),
		    default_colour(Kind, Name)
	    end
    end.

default_colour(K, _N) when K =:= plot; K =:= plotin -> {?PHOSPHOR, "#152515"};
default_colour(K, N) when K =:= toggle; K =:= push; K =:= lamp;
			  K =:= action -> hue(N);
default_colour(K, _N) when K =:= value; K =:= invalue -> {"#eee", "#222"};
default_colour(_K, _N) -> {"#3af", "#101825"}.

parse_colour("#" ++ Hex) ->
    case expand_hex(Hex) of
	{ok, H} -> {ok, {"#" ++ H, dim(H)}};
	none    -> none
    end;
parse_colour("0x" ++ Hex) when length(Hex) =:= 6 ->
    parse_colour("#" ++ Hex);
parse_colour(Name) ->
    palette(Name).

expand_hex(H) ->
    case lists:all(fun(C) -> lists:member(C, "0123456789abcdef") end, H) of
	true when length(H) =:= 6 -> {ok, H};
	true when length(H) =:= 3 -> {ok, lists:append([[C, C] || C <- H])};
	_                         -> none
    end.

%% The unlit colour: the same hue at a seventh of the brightness, which is
%% about where the palette's hand-picked ones sit.
dim(H) ->
    [R, G, B] = [list_to_integer(lists:sublist(H, I, 2), 16) div 7
		 || I <- [1, 3, 5]],
    lists:flatten(io_lib:format("rgb(~w,~w,~w)", [R, G, B])).

%% A bare word arrives as text, a number as the text that was typed, `key'
%% alone as true.
to_text(true)              -> "true";
to_text(V) when is_list(V) -> V;
to_text(V)                 -> lists:flatten(io_lib:format("~p", [V])).

%% The scanner hands a quoted string over as the file's BYTES, so "°C" is two
%% characters of mojibake. Decoded here -- but only into Latin-1, because wse
%% sends a list with anything above 255 in it as an array rather than a string,
%% and the label would arrive as numbers.
utf8(S) when is_list(S) ->
    try unicode:characters_to_list(list_to_binary(S)) of
	L when is_list(L) ->
	    case lists:all(fun(C) -> C =< 255 end, L) of
		true  -> L;
		false -> S
	    end;
	_ -> S
    catch _:_ -> S
    end;
utf8(V) -> to_text(V).

%%% --------------------------------------------------------------- plots
%%%
%%% The first widget that is not one declaration. Two channels that share `id'
%%% are one picture, and `axis' says which way each one goes:
%%%
%%%     #analog xin:10 in unsigned 0
%%%     #analog yin:10 in unsigned 1
%%%     #annotate panel xin kind=plot axis=x id=plot1 scale=0.000976 unit="ms"
%%%     #annotate panel yin kind=plot axis=y id=plot1 scale=0.000976 unit="V"
%%%
%%% The grouping is deliberately NOT in widgets/1. That answers "what is this
%%% declaration", one tuple per declaration, and everything above depends on
%%% that shape. The group is read off the same annotations here, next to the
%%% drawing that needs it.

plots(Ast) ->
    plot_groups([W || W <- widgets(Ast), is_plot(W)], annotations(Ast),
		ranges(Ast)).

%%% What a channel's full swing IS, taken from the declaration.
%%%
%%% An #analog or a #field without `unsigned' is SIGNED, and a plot that assumes
%%% 0..full-scale then draws the top half of the picture and clips everything
%%% below zero into the bottom edge. A sixteen-bit signed field fed from a socket
%%% is exactly that case.
%%%
%%% A one-bit field is the exception: typeless leaves are signed except at :1.
%%% The annotation's min/max still wins over all of it.
ranges(Ast) ->
    lists:foldl(
      fun({analog, _Ln, {'WORD', _, N}, scalar, Res, Opts, _E}, M) ->
	      M#{N => swing(width(Res), Opts)};
	 ({field, _Ln, {'WORD', _, N}, Res, Opts, _Buf, Pos}, M) ->
	      M#{N => swing(field_width(Res, Pos), Opts)};
	 (_, M) -> M
      end, #{}, Ast).

swing(W, Opts) ->
    case W =:= 1 orelse proplists:get_value(type, Opts) =:= unsigned of
	true  -> {0, full(W)};
	false -> {-(1 bsl (W - 1)), (1 bsl (W - 1)) - 1}
    end.

is_plot({plot, _, _})   -> true;
is_plot({plotin, _, _}) -> true;
is_plot(_)              -> false.

plot_groups([], _Ann, _Rng) ->
    [];
plot_groups(Plots, Ann, Rng) ->
    %% First appearance order, not sorted: the groups should come out in the
    %% order the file declares them, the way every other widget does.
    Ids = lists:foldl(fun({_K, N, _W}, Acc) ->
			      Id = group_of(N, Ann),
			      case lists:member(Id, Acc) of
				  true  -> Acc;
				  false -> Acc ++ [Id]
			      end
		      end, [], Plots),
    [group(Id, [P || P <- Plots, group_of(nm(P), Ann) =:= Id], Ann, Rng)
     || Id <- Ids].

nm({_K, N, _W}) -> N.

%% No id at all is ONE group. Two channels and a plot is the common case and
%% should not need ceremony to say so.
group_of(Name, Ann) -> maps:get("id", kv(Name, Ann), "plot").

%% A signal's own keys over the panel's `*' defaults.
kv(Name, Ann) ->
    maps:merge(maps:without(?OWN_KEYS, maps:get("*", Ann, #{})),
	       maps:get(Name, Ann, #{})).

group(Id, Members, Ann, Rng) ->
    Ms = [member(P, Ann, Rng) || P <- Members],
    {Xs, Ys, Bare} = by_axis(Ms),
    {X, Rest} = pick_x(Id, Xs, Bare),
    Round = shape(Id, gopt("shape", Ms, "square")),
    Beam = num(gopt("beam", Ms, ?BEAM_W)),
    #{id => Id, x => X, ys => Ys ++ Rest, sweep => 0, prev => #{},
      persist => num(gopt("persist", Ms, ?PERSIST)),
      round => Round,
      %% The beam: line width, the radius of the dot at its head (0 for none),
      %% the bloom, and whether a sample HOLDS until the next one. Thin, no dot,
      %% no glow and line=step is what draws a square wave as a square.
      beam => Beam,
      dot  => num(gopt("dot", Ms, Beam * 1.5)),
      glow => onoff(Id, "glow", #{"glow" => gopt("glow", Ms, true)}, true),
      step => line_of(Id, gopt("line", Ms, "straight")),
      %% The glass decides by default: a round face that paints into its own
      %% corners is a square picture behind a round bezel. `clip=off' keeps the
      %% painting square -- which is worth having, because a clip hides a
      %% reading that has left the glass with nothing to say it did.
      clip => clip(Id, gopt("clip", Ms, none), Round)}.

%% A channel is its look plus what only a plot needs. The beam is the lit
%% colour alone: a trail has no "off".
member(P = {Kind, Name, _W}, Ann, Rng) ->
    Kv = kv(Name, Ann),
    L = look(P, Kv, Rng),
    {On, _Off} = maps:get(colour, L),
    L#{name   => Name,
       kind   => Kind,
       axis   => axis_of(Name, Kv),
       colour => On,
       kv     => Kv}.

axis_of(Name, Kv) ->
    case maps:get("axis", Kv, none) of
	none -> none;
	"x"  -> "x";
	"y"  -> "y";
	Bad  -> io:format("panel: ~s: axis=~s is neither x nor y~n", [Name, Bad]),
		none
    end.

by_axis(Ms) ->
    lists:foldr(fun(M, {X, Y, B}) ->
			case maps:get(axis, M) of
			    "x" -> {[M | X], Y, B};
			    "y" -> {X, [M | Y], B};
			    _   -> {X, Y, [M | B]}
			end
		end, {[], [], []}, Ms).

%% An axis nobody named is guessed -- first channel across, the rest up -- and
%% the guess is SAID. A plot drawn from a silent guess is a picture of something
%% else, and nothing on screen tells you which.
pick_x(_Id, [X], Bare) ->
    {X, Bare};
pick_x(Id, [], [X | Bare]) ->
    io:format("panel: ~s: no axis=x, taking ~s as x~n", [Id, maps:get(name, X)]),
    {X, Bare};
pick_x(Id, [X | More], Bare) ->
    io:format("panel: ~s: more than one axis=x, keeping ~s~n",
	      [Id, maps:get(name, X)]),
    {X, More ++ Bare};
%% Only y channels. Then there is nothing to put across, so the beam sweeps:
%% the plot degrades to an ordinary scope with time along the bottom, which is
%% the one reading that cannot be wrong. See plot_tick/3.
pick_x(_Id, [], []) ->
    {undefined, []}.

%% A setting that belongs to the PICTURE, said on whichever channel the hand
%% reached first: the phosphor and the glass are not properties of a channel.
gopt(_Key, [], Default) ->
    Default;
gopt(Key, [M | T], Default) ->
    case maps:get(Key, maps:get(kv, M), none) of
	none -> gopt(Key, T, Default);
	V    -> V
    end.

line_of(_Id, "straight") -> false;
line_of(_Id, "step")     -> true;
line_of(Id, Other) ->
    io:format("panel: ~s: line=~s is neither straight nor step~n", [Id, Other]),
    false.

shape(_Id, "round")  -> true;
shape(_Id, "square") -> false;
shape(Id, Other) ->
    io:format("panel: ~s: shape=~s is neither round nor square~n", [Id, Other]),
    false.

clip(_Id, none, Round)  -> Round;       % the glass decides
clip(_Id, "on", _R)     -> true;
clip(_Id, "off", _R)    -> false;
clip(Id, Other, Round) ->
    io:format("panel: ~s: clip=~s is neither on nor off~n", [Id, Other]),
    Round.

%% An annotation value arrives as the TEXT that was typed -- scale=0.000976 is
%% a float, min=0 an integer, and a quoted string is whatever is inside it.
%% max=0x3FF is hex, as everywhere else in candyspeak.
num(V) when is_integer(V) -> V;
num(V) when is_float(V)   -> V;
num("-0x" ++ H)           -> -num("0x" ++ H);
num("0x" ++ H)            ->
    try list_to_integer(H, 16) catch _:_ -> 0 end;
num(S) when is_list(S)    ->
    %% {error, Reason} is a two-tuple like {Float, Rest}, so the shape alone does
    %% not tell them apart -- the guard is what does.
    case string:to_float(S) of
	{F, _} when is_float(F) -> F;
	_ ->
	    case string:to_integer(S) of
		{I, _} when is_integer(I) -> I;
		_                         -> 0
	    end
    end;
num(_) -> 0.

%% Value to pixel, inset by the beam's own radius so a reading at full scale is
%% a whole dot rather than half of one at the edge.
pos(V, #{min := Min, max := Max}, Len) ->
    Span = max(Max - Min, 1),
    Cl = min(max(V, Min), Max),
    ?PAD + trunc((Cl - Min) * (Len - 2 * ?PAD) / Span).

px(V, M) -> pos(V, M, ?PLOT_W).
py(V, M) -> ?PLOT_W - 1 - pos(V, M, ?PLOT_W).

%% The count as csp has it, and -- when the annotation says what a count means
%% -- what it is in the world. A scale with no unit is still worth printing; a
%% unit with no scale means the count IS the unit.
eng(V, #{scale := S, unit := U}) when S == 1 ->
    case U of
	"" -> integer_to_list(V);
	_  -> [integer_to_list(V), " ", U]
    end;
eng(V, #{scale := S, unit := U}) ->
    io_lib:format("~w  ~.3f ~s", [V, V * S, U]).

%%% ---------------------------------------------------------------- rendering

build(Ws, Where, Root, File, [], Ast, Chat) ->
    %% Parsed fine, but nothing in it is a widget yet. Say which declarations
    %% it does have -- an empty panel otherwise looks like a failure.
    {_SelId, _Sel, _Run} = chooser(Ws, Root, File, Chat),
    text(Ws, Root, io_lib:format(
		     "nothing to show in ~s.~n~n"
		     "it declares: ~s~n~n"
		     "widgets come from #digital, #analog and #field; variables "
		     "and rules are not shown yet.",
		     [shorten(File), kinds(Ast)])),
    wait_for_pick(Ws, Where, Chat);
build(Ws, Where, Root, File, Widgets0, Ast, Chat) ->
    {SelId, _Sel, Run} = chooser(Ws, Root, File, Chat),
    %% Everything in one window. The TOP frame is where the program is: State,
    %% cycle and clock, the goal and solve, varp's answer, the values. Under
    %% it the devices on the left and the code view on the right, each
    %% scrolling on its own, and the trace at the bottom -- so the rule that
    %% lights and the lamp it drives are side by side, and neither scrolls
    %% the other out of view.
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
    Ann = annotations(Ast),
    Rng = ranges(Ast),
    Looks = looks(Widgets0, Ann, Rng),
    [warn_misplaced(W, Ann) || W <- Widgets0],
    %% hidden: no row, no trace, not a channel of any plot. csp still has it;
    %% the panel just does not show it.
    Widgets = [W || W = {_, N, _} <- Widgets0,
		    not maps:get(hidden, maps:get(N, Looks))],
    %% Two kinds do not get a row of their own: pixels are one strip (strip/3)
    %% and a plot's channels are one picture (plot_panel/4).
    {Pixels, Rest0} = lists:partition(fun({K, _, _}) -> K =:= pixel end,
				      Widgets),
    {Plots, Rest} = lists:partition(fun is_plot/1, Rest0),
    RestNodes = [{Name, row(Ws, Left, W, maps:get(Name, Looks))}
		 || W = {_, Name, _} <- Rest],
    PixNodes = strip(Ws, Left, [{N, maps:get(N, Looks)}
				|| {_, N, _} <- Pixels]),
    {Groups, PlotNodes} = plot_panels(Ws, Left,
				      plot_groups(Plots, Ann, Rng)),
    %% A plot channel still gets a TIME trace below. The XY picture says where
    %% the beam is and nothing about when it got there -- which of the two you
    %% need depends on what is wrong, so the panel shows both.
    %% trace=off leaves a signal out of it, and `* trace=off' leaves the trace
    %% out altogether -- a panel that is only there to drive a GUI has no use
    %% for a logic analyser underneath it.
    Ordered = [T || T = {_, N, _} <- Rest ++ Pixels ++ Plots,
		    maps:get(trace, maps:get(N, Looks))],
    {Ctx, Paint} = canvas(Ws, TraceBox, [maps:get(N, Looks)
					 || {_, N, _} <- Ordered]),
    {ok, Src} = candyspeak:parse(File, [sources]),
    Code = csp_code:new(Ws, #{code => Right, status => Status, top => Top},
			{Src, File}, colours()),
    {ok, Link} = csp_link:open(target(), csp_exe(), [File]),
    erlang:send_after(period(), self(), tick),
    S0 = #{trace_box => TraceBox, code => Code, run => Run},
    S1 = lists:foldl(fun({K, V}, Si) -> view(Ws, Si, K, V) end, S0,
		     maps:to_list(views())),
    S2 = #{nodes  => maps:from_list(RestNodes ++ PixNodes ++
						  PlotNodes),
		     traces => [{N, K, maps:get(N, Looks)} || {K, N, _} <- Ordered],
		     ctx    => Ctx,
		     paint  => Paint,
		     plots  => Groups,
		     period => period(),
		     x      => 0,
		     last   => #{},
		     sel_id => SelId,
		     run    => Run,
		     mode   => run,
		     clock  => {0, undefined},
		     code   => maps:get(code, S1),
		     trace_box => TraceBox,
		     state_box => StateBox,
		     clock_box => Clock,
		     link_box => LinkBox,
		     file   => File,
		     chat   => Chat,
		     where  => Where},
    csp_chat:attach(Chat, chat_info(File)),
    loop(Ws, Link, start_mode(Ws, Link, S2)).

%% {mode, pause} in candid.config: start stopped, ready to step. Not a node: it
%% was running before we looked, and connecting is not a reason to stop it.
start_mode(Ws, Link, S) ->
    case {config(mode), target()} of
	{pause, {{local, _}, _}} -> control(Ws, Link, S, "mode=step");
	_ -> light_mode(Ws, S#{mode := run}), S#{mode := run}
    end.

%% What the panel is connected to, csp_link:target/1's reading of the field.
%% Kept across a change of file, which rebuilds everything else.
target() ->
    case get(candid_target) of
	undefined -> {ok, T} = csp_link:target(""), T;
	T -> T
    end.

target_text() ->
    case get(candid_target_text) of
	undefined -> "";
	T -> T
    end.

%% A new target from the field: let go of this one and connect to that, the
%% widgets and the code view as they are. A field that does not read stays
%% connected where it was, and says why.
retarget(Ws, Link, S, Text) ->
    case csp_link:target(Text) of
	{ok, T} ->
	    csp_link:close(Link),
	    flush(),
	    put(candid_target, T),
	    put(candid_target_text, Text),
	    {ok, Link1} = csp_link:open(T, csp_exe(), [maps:get(file, S)]),
	    {Link1, start_mode(Ws, Link1, S#{last := #{}})};
	{error, Why} ->
	    show_link(Ws, S, Why),
	    {Link, S}
    end.

%% What the chat is told after every rebuild: what is shown, and where it runs.
chat_info(File) ->
    #{file => File, target => target_text(), local => is_local()}.

is_local() ->
    case target() of
	{{local, _}, _} -> true;
	_ -> false
    end.

%% Where a node's listing is kept: named after the target, so the chooser
%% says which node the program came from.
node_file(Target) ->
    Name = [case C of $/ -> $_; $\s -> $_; _ -> C end
	    || C <- string:trim(hd(string:lexemes(Target ++ " ", " ")), leading,
				"/")],
    filename:join([os:getenv("TMPDIR", "/tmp"), "csp_node", Name ++ ".csp"]).

show_link(Ws, #{link_box := {B, F}}, Text) ->
    wse:cast(Ws, F, "call", [null, B, lists:flatten(Text)]);
show_link(_Ws, _S, _Text) ->
    ok.

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

%%% What is shown: the trace (hide | show), the code view (hide | ladder |
%%% code) and the theme (dark | light). Both views start hidden unless
%%% candid.config says otherwise:
%%%
%%%     {candid, [{trace, show}, {code, ladder}, {theme, light}]}
%%%
%%% Kept per browser session in the process dictionary, so picking another
%%% program keeps them -- render/3 starts the page over, and the choice is the
%%% person's, not the program's.
-define(VIEWS, [{"trace", ["hide", "show"]},
		{"code",  ["hide", "ladder", "code"]},
		{"theme", ["dark", "light"]}]).

views() ->
    case get(candid_views) of
	undefined -> configured();
	V         -> V
    end.

%% The first of each list unless candid.config names another. A value the bar
%% has no button for is said, not taken.
configured() ->
    maps:from_list(
      [{K, case config(list_to_atom(K)) of
	       undefined -> hd(Vals);
	       V0 ->
		   V = to_text(V0),
		   case lists:member(V, Vals) of
		       true  -> V;
		       false ->
			   io:format("panel: candid.config: {~s, ~s} is not one "
				     "of ~s~n", [K, V, string:join(Vals, ", ")]),
			   hd(Vals)
		   end
	   end} || {K, Vals} <- ?VIEWS]).

%% candid.config's {candid, [...]}. The application is only loaded to make
%% the environment reachable: -config keeps nothing for one nobody loaded.
config(Key) ->
    _ = application:load(candid),
    case application:get_env(candid, Key) of
	{ok, V}   -> V;
	undefined -> undefined
    end.

%% {colors, [{true, "#3f3"}, {fired, orange}]}: the code view's highlights,
%% any css colour. See csp_code for the names.
colours() ->
    case config(colors) of
	L when is_list(L) -> maps:from_list([{K, to_text(C)} || {K, C} <- L]);
	_                 -> #{}
    end.

view(Ws, S, "trace", V) ->
    style(Ws, maps:get(trace_box, S),
	  [?TRACE_BOX, case V of "show" -> "display:block";
			   _      -> "display:none"
		       end]),
    view_done(Ws, S, "trace", V);
view(Ws, S, "code", V) ->
    S1 = S#{code := csp_code:control(Ws, maps:get(code, S), V)},
    view_done(Ws, S1, "code", V);
view(Ws, S, "theme", V) ->
    theme(Ws, V),
    view_done(Ws, S, "theme", V);
view(_Ws, S, _K, _V) ->
    S.

view_done(Ws, S, K, V) ->
    put(candid_views, maps:put(K, V, views())),
    [style(Ws, B, btn_style(Val =:= V))
     || {{K1, Val}, B} <- maps:to_list(maps:get(views, maps:get(run, S))),
	K1 =:= K],
    S.

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

%% Lists every .csp under demo/ and the tree's examples/, so another program is
%% a pick rather than an edit of the page.
chooser(Ws, Root, Current, Chat) ->
    Bar = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Bar, "font:14px monospace;color:#888;margin-bottom:12px"),
    Sel = wse:createElement(Ws, "select"),
    wse:setStyle(Ws, Sel, "font:14px monospace;background:#222;color:#eee;"
		 "border:1px solid #555;padding:3px"),
    lists:foreach(
      fun(F) ->
	      O = wse:createElement(Ws, "option"),
	      wse:set(Ws, O, "value", F),
	      wse:appendChild(Ws, O, wse:createTextNode(Ws, shorten(F))),
	      case F =:= Current of
		  true  -> wse:set(Ws, O, "selected", true);
		  false -> ok
	      end,
	      wse:appendChild(Ws, Sel, O)
      end, available(Current)),
    {ok, Id} = wse:create_event(Ws),
    %% `this` in an onchange assigned this way is the select, so the new
    %% filename rides along and the loop needs no reverse map.
    Func = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			", this.value); }"),
    wse:set(Ws, Sel, "onchange", Func),
    wse:appendChild(Ws, Bar, Sel),
    Run = runstep(Ws, Bar, Chat),
    wse:appendChild(Ws, Root, Bar),
    {Id, Sel, Run}.

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
runstep(Ws, Bar, Chat) ->
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
    target_field(Ws, Wrap, Id),
    RunB  = Mk("run",   "mode=run"),
    PauseB = Mk("pause", "mode=step"),
    OneB  = Mk("step",  "step=1"),
    %% The tick, on the SAME event as the buttons: the loop already tells the
    %% bar's events from a widget's by the id, and tags its payloads, so this
    %% needs no second wire. `period=25' lands in control/4 beside `mode=run'.
    tick_select(Ws, Wrap, Id),
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
			  || {K, Vals} <- ?VIEWS]),
    %% Only when there is a chat to open: ellm on the path, not switched off.
    Chat =/= undefined andalso
	begin
	    L = wse:createElement(Ws, "span"),
	    wse:setStyle(Ws, L, "margin-left:16px"),
	    wse:appendChild(Ws, Wrap, L),
	    Mk("chat", "chat=toggle")
	end,
    wse:appendChild(Ws, Bar, Wrap),
    #{event => Id, run => RunB, pause => PauseB, one => OneB,
      views => maps:from_list(Views)}.

%% Where the program is: its cycle and its own clock, which stand still while
%% paused.
clock_text(Cycle, Prog) ->
    lists:flatten(io_lib:format("cycle ~w   time ~s", [Cycle, secs(Prog)])).

secs(undefined) -> "-";
secs(Ms)        -> io_lib:format("~.1f s", [Ms / 1000]).

%% Where the program runs: a csp of our own, or a node. Read by
%% csp_link:target/1, sent on Enter.
target_field(Ws, Wrap, Id) ->
    In = wse:createElement(Ws, "input"),
    wse:set(Ws, In, "type", "text"),
    wse:set(Ws, In, "value", target_text()),
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

tick_select(Ws, Wrap, Id) ->
    Lbl = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, Lbl, "margin-left:12px;color:#888;font:12px monospace"),
    wse:appendChild(Ws, Lbl, wse:createTextNode(Ws, "tick")),
    wse:appendChild(Ws, Wrap, Lbl),
    Sel = wse:createElement(Ws, "select"),
    wse:setStyle(Ws, Sel, "margin-left:6px;font:12px monospace;background:#222;"
		 "color:#eee;border:1px solid #555;padding:2px"),
    Now = period(),
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
      end, lists:usort([Now | ?PERIODS])),
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

%% Held down rather than latched: mousedown sends 1, mouseup sends 0. Reuses the
%% slider wire format (Name=Value) rather than inventing a second one.
push(Ws, Row, Name, #{colour := Hue}) ->
    B = wse:createElement(Ws, "button"),
    wse:setStyle(Ws, B, "width:60px;padding:4px;font:14px monospace;"
		 "background:#333;color:#eee;border:1px solid #555"),
    wse:appendChild(Ws, B, wse:createTextNode(Ws, "0")),
    {ok, Id} = wse:create_event(Ws),
    Down = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			", '" ++ Name ++ "=1'); }"),
    Up = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
		      ", '" ++ Name ++ "=0'); }"),
    wse:set(Ws, B, "onmousedown", Down),
    wse:set(Ws, B, "onmouseup", Up),
    wse:set(Ws, B, "onmouseleave", Up),     % dragging off must not leave it held
    wse:appendChild(Ws, Row, B),
    {switch, B, Hue}.

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
    Deg = -135 + trunc(270 * frac(V, Look)),
    ["position:absolute;left:50%;top:50%;width:2px;height:15px;"
     "background:", On, ";transform-origin:50% 100%;"
     "transform:translate(-50%,-100%) rotate(", integer_to_list(Deg), "deg)"].

%% Where V sits between min and max, 0.0..1.0, clamped: a reading outside the
%% range pins the needle rather than spinning it round the back.
frac(V, #{min := Min, max := Max}) ->
    (min(max(V, Min), Max) - Min) / max(Max - Min, 1).

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
    xy_handler(Ws, C, drivable(X, Ys)),
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

%% Which channels the pointer may drive: the ones whose declaration is an INPUT.
%% A plot of two outputs is a picture and nothing else, and must not pretend
%% otherwise by moving when you touch it.
drivable(X, Ys) ->
    Across = [{across, M} || M <- [X], M =/= undefined,
			     maps:get(kind, M) =:= plotin],
    %% One y, not all of them: every y channel reads the same pointer height, so
    %% driving several from one move would set them all to the same value.
    Up = case [M || M <- Ys, maps:get(kind, M) =:= plotin] of
	     [M | _] -> [{up, M}];
	     []      -> []
	 end,
    Across ++ Up.

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

%% How much of the last frame survives one tick: the fraction each pixel's
%% distance from the background is multiplied by.
%%
%% Scaled by the TICK, because persistence is a time and not a number of frames.
%% `persist=0.9' means 90% left after 100 ms, at any tick; without the scaling
%% the same number at 10 ms would decay ten times as fast and the trail would
%% vanish the moment you asked for a faster tick -- which is exactly when you
%% want to see it. persist=0 is no trail at all, just the beam.
keep(P, Ms) ->
    K = min(0.999, max(0.0, P)),
    math:pow(K, Ms / ?PERIOD).

readout(Ws, Row) ->
    T = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, T, "margin-left:10px;color:#888;font:12px monospace"),
    wse:appendChild(Ws, T, wse:createTextNode(Ws, "")),
    wse:appendChild(Ws, Row, T),
    T.

switch(Ws, Row, Name, #{colour := Hue}) ->
    B = wse:createElement(Ws, "button"),
    wse:setStyle(Ws, B, "width:60px;padding:4px;font:14px monospace;"
		 "background:#333;color:#eee;border:1px solid #555"),
    wse:appendChild(Ws, B, wse:createTextNode(Ws, "0")),
    {ok, Id} = wse:create_event(Ws),
    Func = wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++
			",'" ++ Name ++ "'); }"),
    wse:set(Ws, B, "onclick", Func),
    wse:appendChild(Ws, Row, B),
    {switch, B, Hue}.

lamp(Ws, Row, #{colour := Hue}) ->
    L = wse:createElement(Ws, "span"),
    wse:setStyle(Ws, L, ?LAMP ?LAMP_OFF),
    wse:appendChild(Ws, Row, L),
    {lamp, L, Hue}.

%% Take the hint from the name. A traffic light whose lamps all glow green is
%% harder to read than one that looks like a traffic light, and the name is the
%% only thing that knows -- the declaration says `out 5`, nothing about colour.
%% A plain `Led` stays red, which is what a bare indicator LED usually is.
%%
%% A `__Colour` SUFFIX says it outright, for the cases no word in the name
%% implies: `Heater__Orange`, `BathFan__Blue`. The suffix is stripped from the
%% label, so the panel shows `Heater` -- see label_of/1.
%%
%% This is a stopgap for demos and development, not a design. It puts
%% presentation into the identifier, which then has to be spelled out in every
%% rule that touches it. `#annotate panel X color=...' is the right answer and
%% wins over both guesses -- see colour/3.
hue(Name) ->
    case suffix_colour(Name) of
	{ok, Hue} -> Hue;
	none      -> hue_from_words(Name)
    end.

%% Everything after the last "__", matched against the palette.
suffix_colour(Name) ->
    case string:split(Name, "__", trailing) of
	[_, Tail] when Tail =/= [] -> palette(string:lowercase(Tail));
	_                          -> none
    end.

palette("red")     -> {ok, {"#f44", "#251515"}};
palette("orange")  -> {ok, {"#f92", "#251a10"}};
palette("yellow")  -> {ok, {"#fd3", "#252210"}};
palette("amber")   -> {ok, {"#fb2", "#251c0c"}};
palette("green")   -> {ok, {"#3f3", "#152515"}};
palette("cyan")    -> {ok, {"#3dd", "#102525"}};
palette("blue")    -> {ok, {"#5af", "#101825"}};
palette("purple")  -> {ok, {"#b7f", "#1d1526"}};
palette("pink")    -> {ok, {"#f7b", "#261520"}};
palette("white")   -> {ok, {"#eee", "#222"}};
palette(_)         -> none.

hue_from_words(Name) ->
    Lower = string:lowercase(Name),
    Hit = fun(S) -> string:find(Lower, S) =/= nomatch end,
    case Hit("green") orelse Hit("gron") orelse Hit("grn") of
	true -> {"#3f3", "#152515"};
	false ->
	    case Hit("yellow") orelse Hit("amber") orelse Hit("gul") of
		true -> {"#fd3", "#252210"};
		false ->
		    case Hit("blue") orelse Hit("bla") of
			true -> {"#5af", "#101825"};
			false ->
			    case Hit("white") orelse Hit("vit") of
				true  -> {"#eee", "#222"};
				%% red: Red, Rod, and everything unlabelled
				false -> {"#f44", "#251515"}
			    end
		    end
	    end
    end.

%% What the panel shows. The csp name keeps its suffix -- that is what the
%% dump and every rule call it -- but nobody wants to read it.
label_of(Name) ->
    case string:split(Name, "__", trailing) of
	[Head, Tail] when Head =/= [], Tail =/= [] ->
	    case palette(string:lowercase(Tail)) of
		{ok, _} -> Head;         % a colour: hide it
		none    -> Name          % something else: leave it alone
	    end;
	_ -> Name
    end.

%% No rows, no canvas: draw/2 then only moves the plots.
canvas(_Ws, _Root, []) ->
    {undefined, undefined};
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

%% Nothing to drive, so there is no csp and no tick -- just the chooser.
wait_for_pick(Ws, Where, Chat) ->
    receive
	{notify, _Id, _Local, File} -> render(Ws, Where, File, Chat);
	{closed, _}                 -> ok;
	stop                        -> ok
    end.

%% Which declaration types a file actually has, counted, for the message above.
kinds(Ast) ->
    Counts = lists:foldl(fun(D, M) when is_tuple(D) ->
				 K = element(1, D),
				 maps:update_with(K, fun(N) -> N + 1 end, 1, M);
			    (_, M) -> M
			 end, #{}, Ast),
    string:join([io_lib:format("~w x~w", [K, N])
		 || {K, N} <- lists:sort(maps:to_list(Counts))], ", ").

%%% --------------------------------------------------------------------- loop

loop(Ws, Link, S) ->
    SelId = maps:get(sel_id, S),
    %% Bound before the receive so the clause can match on it: a guard may not
    %% call maps:get, and matching a bound variable is what tells the bar's
    %% events apart from a widget's without reading the payload.
    RunId = maps:get(event, maps:get(run, S, #{event => undefined}),
		     undefined),
    CodeId = case maps:get(code, S, undefined) of
		 undefined -> undefined;
		 #{event := Ce} -> Ce
	     end,
    receive
	%% Another program was picked: drop this csp and rebuild from that file.
	{notify, SelId, _Local, File} ->
	    csp_link:close(Link),
	    flush(),
	    render(Ws, maps:get(where, S), File, maps:get(chat, S));

	%% run / pause / step. Sent by the bar, and told apart from a widget by
	%% the event id rather than by the payload, so a signal called "step"
	%% could not be mistaken for the button.
	{notify, RunId, _Local, "target=" ++ Text} ->
	    {Link1, S1} = retarget(Ws, Link, S, Text),
	    csp_chat:attach(maps:get(chat, S1), chat_info(maps:get(file, S1))),
	    loop(Ws, Link1, S1);
	{notify, RunId, _Local, "chat=toggle"} ->
	    csp_chat:toggle(maps:get(chat, S)),
	    loop(Ws, Link, S);

	%% The chat asks what only the panel knows, or to act as a button or
	%% the chooser would -- so the bar shows what happened.
	{chat_tool, From, Ref, Name, Args} ->
	    Info = #{last => maps:get(last, S), clock => maps:get(clock, S),
		     mode => maps:get(mode, S, run), local => is_local(),
		     link => Link},
	    case csp_chat:panel_tool(Name, Args, Info) of
		{load, File, Reply} ->
		    From ! {Ref, Reply},
		    csp_link:close(Link),
		    flush(),
		    render(Ws, maps:get(where, S), File, maps:get(chat, S));
		{control, Tag, Reply} ->
		    From ! {Ref, Reply},
		    loop(Ws, Link, control(Ws, Link, S, Tag));
		Reply ->
		    From ! {Ref, Reply},
		    loop(Ws, Link, S)
	    end;
	{notify, RunId, _Local, Tag} ->
	    loop(Ws, Link, control(Ws, Link, S, Tag));

	%% ladder / code, from the code view's own bar.
	{notify, CodeId, _Local, Tag} ->
	    loop(Ws, Link, code_do(Ws, Link, S,
				   csp_code:control(Ws, maps:get(code, S), Tag)));

	%% A switch was clicked. We do not track its state ourselves -- we
	%% toggle against what csp last told us, so the button can never
	%% disagree with the program.
	{notify, _Id, _Local, Data} ->
	    case string:split(Data, "=") of
		[Name, Val] ->
		    %% a slider: send the value it was dragged to
		    csp_link:set(Link, Name, Val);
		[Name] ->
		    %% a switch: toggle against what csp last told us, so the
		    %% button can never disagree with the program
		    Cur = maps:get(Name, maps:get(last, S), 0),
		    csp_link:set(Link, Name, case Cur of 0 -> 1; _ -> 0 end)
	    end,
	    loop(Ws, Link, S);

	{csp_state, _N, Vals} ->
	    loop(Ws, Link, update(Ws, S, Vals));

	{csp_fired, _N, Rules} ->
	    loop(Ws, Link,
		 S#{code := csp_code:fired(Ws, maps:get(code, S), Rules)});

	{csp_clock, N, Ms} ->
	    loop(Ws, Link, S#{clock := {N, Ms}});

	%% varp's answer to the code view's clear or solve.
	{csp_model, A} ->
	    loop(Ws, Link, code_do(Ws, Link, S,
				   csp_code:model(Ws, maps:get(code, S), A)));

	%% Draw on the TICK, not on the dump. csp only dumps what changed, so a
	%% trace driven by dumps stops moving as soon as the program settles --
	%% which is exactly when you are staring at it wondering why. Drawing
	%% here also means the x axis is wall time, not cycle number.
	%% The timer keeps arriving while stepping -- it just does not drive the
	%% program. Drawing still happens, so a held value stays visible as a
	%% flat line rather than the trace freezing mid-air.
	tick ->
	    show_clock(Ws, S),
	    S1 = (draw(Ws, S))#{code := csp_code:tick(Ws, maps:get(code, S))},
	    case maps:get(mode, S, run) of
		run  -> csp_link:tick(Link);
		step -> ok
	    end,
	    erlang:send_after(maps:get(period, S, ?PERIOD), self(), tick),
	    loop(Ws, Link, S1);

	{csp_link, Text} ->
	    show_link(Ws, S, Text),
	    loop(Ws, Link, S);

	%% A node's program, listed off its image: the panel is rebuilt from it,
	%% so the code and the widgets are what RUNS there and not whatever
	%% file happened to be open. Once it shows that program this is a no-op,
	%% which is what keeps the reconnect after the rebuild from looping.
	{csp_program, Text} ->
	    File = node_file(target_text()),
	    Bin = unicode:characters_to_binary(Text),
	    case file:read_file(maps:get(file, S)) of
		{ok, Bin} ->
		    loop(Ws, Link, S);
		_ ->
		    ok = filelib:ensure_dir(File),
		    ok = file:write_file(File, Bin),
		    csp_link:close(Link),
		    flush(),
		    render(Ws, maps:get(where, S), File, maps:get(chat, S))
	    end;

	%% csp ended, or the node went away. The panel stays: another target
	%% can be typed in.
	{csp_exit, _Status} ->
	    loop(Ws, Link, S);
	{closed, _}         -> csp_link:close(Link);
	stop                -> csp_link:close(Link)
    end.

%% What the code view asked csp for: a replayed trace's reset, inputs and
%% steps. A replay runs paused, so the bar says so.
code_do(Ws, Link, S, Code0) ->
    {Acts, Code} = csp_code:actions(Code0),
    lists:foldl(fun(A, Si) -> act(Ws, Link, Si, A) end, S#{code := Code}, Acts).

act(Ws, Link, S = #{mode := run}, pause) -> control(Ws, Link, S, "mode=step");
act(_Ws, _Link, S, pause)                -> S;
act(_Ws, Link, S, reset)                 -> csp_link:reset(Link), S;
act(_Ws, Link, S, {clock, Ms})           -> csp_link:clock(Link, Ms), S;
act(_Ws, _Link, S, {frame, Id, Bytes})    -> send_frame(Id, Bytes), S;
act(_Ws, Link, S, {set, N, V})           -> csp_link:set(Link, N, V), S;
act(_Ws, Link, S, step)                  -> csp_link:step(Link), S.

%% A replayed frame, on the bus csp listens to (--can=vcan0 in csp_link),
%% through the can application `make run' starts. Synchronous, so it is in
%% csp's socket before the step that follows it.
send_frame(Id, Bytes) ->
    try can:sync_send(can:create(Id, list_to_binary(Bytes))) of
	_ -> ok
    catch
	_:Why -> io:format("panel: frame ~.16# not sent: ~p~n", [Id, Why])
    end.

%% Once a tick, and only when the text changed.
show_clock(Ws, #{clock_box := {B, F}, clock := {N, Ms}}) ->
    T = clock_text(N, Ms),
    case get(candid_clock) of
	T -> ok;
	_ -> put(candid_clock, T),
	     wse:cast(Ws, F, "call", [null, B, T])
    end;
show_clock(_Ws, _S) ->
    ok.

%% run: let the program go. step: freeze it, so values set from widgets wait for
%% a /step and are committed together.
control(Ws, Link, S, "mode=run") ->
    csp_link:resume(Link),
    S1 = S#{mode := run},
    light_mode(Ws, S1),
    S1;
control(Ws, Link, S, "mode=step") ->
    csp_link:pause(Link),
    S1 = S#{mode := step},
    light_mode(Ws, S1),
    S1;
control(_Ws, Link, S, "step=1") ->
    %% Only meaningful while stopped; in run mode the program is already going
    %% and a step would be indistinguishable from the tick.
    case maps:get(mode, S, run) of
	step -> csp_link:step(Link, 1);
	run  -> ok
    end,
    S;
%% A new tick takes effect on the NEXT one: the timer already in flight is left
%% to arrive, so changing the rate cannot drop a tick or run two at once.
control(Ws, _Link, S, "trace=" ++ V) -> view(Ws, S, "trace", V);
control(Ws, _Link, S, "code=" ++ V)  -> view(Ws, S, "code", V);
control(Ws, _Link, S, "theme=" ++ V) -> view(Ws, S, "theme", V);
control(_Ws, _Link, S, "period=" ++ Ms) ->
    case string:to_integer(Ms) of
	{N, _} when is_integer(N), N >= 5, N =< 10000 -> S#{period := N};
	_                                             -> S
    end;
control(_Ws, _Link, S, _Other) ->
    S.

%% Which of the three is in force, so the bar says where you are.
light_mode(Ws, S) ->
    #{run := RunB, pause := PauseB, one := OneB} = maps:get(run, S),
    Step = maps:get(mode, S, run) =:= step,
    style(Ws, RunB,   btn_style(not Step)),
    style(Ws, PauseB, btn_style(Step)),
    %% the step button is only live while stopped
    style(Ws, OneB, [btn_style(false),
		     case Step of true -> ";opacity:1"; false -> ";opacity:0.4" end]).

%% Dumps and ticks already in flight belong to the csp we just dropped.
flush() ->
    receive
	{csp_state, _, _} -> flush();
	{csp_fired, _, _} -> flush();
	{csp_clock, _, _} -> flush();
	{csp_model, _}    -> flush();
	{csp_exit, _}     -> flush();
	{csp_link, _}     -> flush();
	{csp_program, _}  -> flush();
	tick              -> flush()
    after 0 -> ok
    end.

%% csp only dumps what changed, so merge into `last` rather than replace it.
%% That is also what makes a trace hold its level between dumps.
%%
%% Paint only what DIFFERS from `last'. A dump is not a list of changes: an
%% object in it comes whole, so bridgezone's 33 objects sent every pin's value
%% some sixty times a second -- and wse:set and setStyle are SYNCHRONOUS, a
%% round trip to the browser each. Measured: 1800 calls a second, nearly all
%% writing what was already there. That was the lag, not the transport.
update(Ws, S, Vals) ->
    Last = maps:get(last, S),
    paint(Ws, S, [{N, V} || {N, V} <- Vals,
			    maps:get(N, Last, undefined) =/= V]),
    Last1 = maps:merge(Last, maps:from_list(Vals)),
    S#{last := Last1,
       code := csp_code:refresh(Ws, maps:get(code, S, undefined), Last1)}.

paint(Ws, S, Vals) ->
    Nodes = maps:get(nodes, S),
    lists:foreach(fun({Name, V}) -> paint1(Ws, maps:find(Name, Nodes), V) end,
		  Vals).

paint1(Ws, {ok, {lamp, Node, {On, Off}}}, V) ->
    style(Ws, Node,
	  case V of
	      0 -> [?LAMP, "background:", Off];
	      _ -> [?LAMP, "background:", On, ";box-shadow:0 0 9px ", On]
	  end);
%% A switch that is on shows it in its colour, so a pressed button reads as
%% pressed without having to read the digit on it.
paint1(Ws, {ok, {switch, Node, {On, _Off}}}, V) ->
    style(Ws, Node, ["width:60px;padding:4px;font:14px monospace;"
		     "border:1px solid #555;",
		     case V of
			 0 -> "background:#333;color:#eee";
			 _ -> ["background:", On, ";color:#111;font-weight:bold"]
		     end]),
    wse:set(Ws, Node, "textContent", label(V));
paint1(Ws, {ok, {meter, Bar, Out, Look = #{colour := {On, _}}}}, V) ->
    Pct = trunc(100 * frac(V, Look)),
    style(Ws, Bar, io_lib:format("display:block;height:100%;"
				 "background:~s;width:~w%", [On, Pct])),
    wse:set(Ws, Out, "textContent", lists:flatten(eng(V, Look)));
paint1(Ws, {ok, {action, Node, Hue}}, V) ->
    style(Ws, Node, action_style(V, Hue)),
    wse:set(Ws, Node, "textContent", case V of 0 -> "off"; _ -> "ON" end);
paint1(Ws, {ok, {dial, Needle, _S, Out, Look}}, V) ->
    style(Ws, Needle, needle_style(V, Look)),
    wse:set(Ws, Out, "textContent", lists:flatten(eng(V, Look)));
paint1(Ws, {ok, {value, Node, Look}}, V) ->
    wse:set(Ws, Node, "textContent", lists:flatten(eng(V, Look)));
%% An input's field is left alone while it is being typed in, same reasoning as
%% the slider: csp owning it would fight the hand.
paint1(_Ws, {ok, {invalue, _Node}}, _V) ->
    ok;
%% A plot channel's number, in engineering units when the annotation gave enough
%% to work them out. The beam is drawn on the tick, not here.
paint1(Ws, {ok, {plotval, Node, M}}, V) ->
    wse:set(Ws, Node, "textContent", lists:flatten(eng(V, M)));
paint1(Ws, {ok, {pixel, Node}}, V) ->
    style(Ws, Node, [?PIXEL, "background:", rgb565(V)]);
%% A slider is an INPUT: csp owning the value would fight the drag, so only the
%% readout follows. The control itself is left where the hand put it.
paint1(Ws, {ok, {slider, _S, Out, Look}}, V) ->
    wse:set(Ws, Out, "textContent", lists:flatten(eng(V, Look)));
paint1(_Ws, _, _V) ->
    ok.

label(0) -> "0";
label(_) -> "1".

%% wse encodes a plain Erlang list as a JSON ARRAY, and only a flat string as a
%% string -- so an iolist handed to setStyle arrives as [["..."],["..."]] and the
%% style is silently dropped. Everything built up from pieces goes through here.
style(Ws, Node, IoList) ->
    wse:setStyle(Ws, Node, lists:flatten(IoList)).

%% One column per tick, drawn incrementally: two fillRects per trace beats
%% redrawing the canvas, and cast/4 does not wait for the browser to answer.
draw(Ws, S) ->
    X = maps:get(x, S),
    Ctx = maps:get(ctx, S),
    Last = maps:get(last, S),
    Ms = maps:get(period, S, ?PERIOD),
    Plots = [plot_tick(Ws, G, Last, Ms) || G <- maps:get(plots, S)],
    if Ctx =:= undefined ->                 % trace=off on `*'
	    S#{plots := Plots};
       X >= ?TRACE_W ->
	    %% wrap, right of the labels
	    wse:cast(Ws, Ctx, "clearRect", [?GUTTER, 0, ?TRACE_W, 4096]),
	    trace_column(Ws, S#{x := 0, plots := Plots});
       true ->
	    trace_column(Ws, S#{plots := Plots})
    end.

trace_column(Ws, S = #{x := X, ctx := Ctx, last := Last}) ->
    {_, Items} =
	lists:foldl(
	  fun({Name, Kind, Look}, {Row, Acc}) ->
		  V = maps:get(Name, Last, 0),
		  {Y, Col} = sample(Row * ?ROW_H + 4, Kind, V, Look),
		  {Row + 1, Acc ++ [?GUTTER + X, Y, Col]}
	  end, {0, []}, maps:get(traces, S)),
    wse:cast(Ws, maps:get(paint, S), "call", [null, Ctx, wse:array(Items)]),
    S#{x := X + ?STEP}.

%% The beam moves on the TICK, like the trace and for the same reason: csp dumps
%% only what changed, so a plot driven by dumps stops the moment the program
%% settles -- and a settled XY reading is still a reading. Drawing here also
%% means the afterglow decays in wall time, which is what makes it read as one.
plot_tick(Ws, G = #{x := undefined}, Last, Ms) ->
    %% No x channel, so the beam sweeps: time along the bottom. See pick_x/3.
    Sw = maps:get(sweep, G),
    G1 = cast_plot(Ws, G, ?PAD + (Sw rem (?PLOT_W - 2 * ?PAD)), Last, Ms),
    G1#{sweep := Sw + 2};
plot_tick(Ws, G = #{x := X}, Last, Ms) ->
    cast_plot(Ws, G, px(val(X, Last), X), Last, Ms).

cast_plot(Ws, G = #{ctx := Ctx, plot := Plot, ys := Ys, persist := P,
		    prev := Prev, round := Rnd, clip := Clip, beam := Beam,
		    dot := Dot, glow := Glow, step := Step}, Px, Last, Ms) ->
    {Items, Prev1} =
	lists:foldl(
	  fun(M, {Acc, Pm}) ->
		  Name = maps:get(name, M),
		  Py = py(val(M, Last), M),
		  {X0, Y0} = seg(maps:get(Name, Pm, none), Px),
		  {Acc ++ [X0, Y0, Px, Py, maps:get(colour, M)],
		   Pm#{Name => {Px, Py}}}
	  end, {[], Prev}, Ys),
    wse:cast(Ws, Plot, "call",
	     [null, Ctx, ?PLOT_W, ?PLOT_W, keep(P, Ms), Rnd, Clip, Beam, Dot,
	      Glow, Step, wse:array(Items)]),
    G#{prev := Prev1}.

%% Where to draw the segment from, or nowhere.
%%
%% A jump of more than half the width ACROSS is a retrace, not a signal: a sweep
%% that reaches the right edge and starts again at the left would otherwise draw
%% a bright diagonal back over the picture every cycle. A scope blanks that, and
%% so does this. A jump UP is left alone -- on a square wave the vertical edge
%% is the signal, and blanking it would hide the only interesting part.
seg(none, _Px) ->
    {-1, -1};
seg({Pxp, Pyp}, Px) ->
    case abs(Px - Pxp) > ?PLOT_W div 2 of
	true  -> {-1, -1};
	false -> {Pxp, Pyp}
    end.

val(M, Last) -> maps:get(maps:get(name, M), Last, 0).

%% Digital is two levels; analog is a height in the row, so the trace reads as a
%% waveform rather than a bit. A pixel is drawn as the colour itself -- a strip
%% of them over time is what a running animation actually looks like.
%% Returns {Y, Colour} for the painter rather than drawing: see painter/1.
%% The height is over the look's min..max, so a signed channel at zero sits in
%% the middle of its row instead of on the floor.
sample(Top, pixel, V, _Look) ->
    {Top, rgb565(V)};
sample(Top, Kind, V, Look = #{colour := {On, _}}) when ?IS_NUMERIC(Kind) ->
    H = ?ROW_H - 12,
    {Top + H - trunc(H * frac(V, Look)), On};
%% The lamp's own colour, so a traffic light's three traces are red, yellow and
%% green rather than three identical stripes.
sample(Top, _Kind, V, #{colour := {On, _Off}}) ->
    case V of
	0 -> {Top + ?ROW_H - 14, "#3a3a4a"};
	_ -> {Top, On}
    end.

%%% -------------------------------------------------------------------- files

available(Current) ->
    Found = lists:append([csp_in(demo_dir()), csp_in(examples_dir())]),
    lists:usort([Current | Found]).

csp_in(Dir) ->
    case file:list_dir(Dir) of
	{ok, Fs} -> [filename:join(Dir, F) || F <- Fs,
					      filename:extension(F) =:= ".csp"];
	_        -> []
    end.

%% The last two components are enough to tell demo/gate.csp from
%% examples/gate.csp, and a full path fills the whole control.
shorten(Path) ->
    filename:join(
      lists:reverse(lists:sublist(lists:reverse(filename:split(Path)), 2))).

default_file() ->
    F = filename:join(demo_dir(), "gate.csp"),
    case filelib:is_regular(F) of
	true  -> F;
	false -> hd(available(F))
    end.

text(Ws, Root, Str) ->
    P = wse:createElement(Ws, "pre"),
    wse:setStyle(Ws, P, "color:#e77;font:13px monospace"),
    wse:appendChild(Ws, P, wse:createTextNode(Ws, lists:flatten(Str))),
    wse:appendChild(Ws, Root, P).

%%% -------------------------------------------------------------------- paths

%% candid's own files are found from where its beam is, candyspeak's (the
%% examples, csp, the manual) from where csp_tools' are -- ERL_LIBS or -pa
%% puts both on the path. Overridable, because when it does not hold the
%% failure is an enoent on a path nobody typed.
demo_dir() ->
    case os:getenv("CANDID_DEMO") of
	false -> filename:join(base(), "demo");
	Dir   -> Dir
    end.

examples_dir() -> filename:join(root(), "examples").
priv_dir()     -> filename:join(base(), "priv").

csp_exe() ->
    Exe = case os:getenv("CSP_EXE") of
	      false -> filename:join(root(), "csp");
	      Path  -> Path
	  end,
    case filelib:is_regular(Exe) of
	true  -> Exe;
	false -> error({csp_not_found, Exe, "set CSP_EXE to the csp binary"})
    end.

%% wse's priv/, taken from where its beam actually is, so the aliased scripts
%% are always the ones belonging to the wse serving the websocket.
wse_priv() ->
    filename:join(filename:dirname(
		    filename:dirname(filename:absname(code:which(wse)))),
		  "priv").

%% absname first: with a relative -pa, code:which/1 answers a relative path
%% and every dirname above would climb out of the wrong tree.
base() ->
    filename:dirname(filename:dirname(filename:absname(code:which(?MODULE)))).

%% candyspeak's tree: csp_tools builds into its top-level ebin/.
root() ->
    case os:getenv("CANDYSPEAK") of
	false ->
	    filename:dirname(filename:dirname(
			       filename:absname(code:which(candyspeak))));
	Dir -> Dir
    end.

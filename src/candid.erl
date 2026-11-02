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

%%%
%%% THE CORE AND ITS RENDERER. This module decides what the panel shows and
%%% runs it; what puts it on a screen is a renderer module -- candid_wse for
%%% the browser -- called through ui/3 with the handle it works on, U =
%%% {Module, Handle}. What a renderer creates comes back as handles kept here
%%% and given back to it; what the person does comes back as messages, which
%%% Module:event/2 reads into {pick, File}, {bar, Tag}, {code, Tag} or
%%% {widget, Data}. The trace and the plots are computed here in candid.hrl's
%%% pixels, and the renderer only puts the dots there.

-module(candid).

-export([start/0, start/2]).
-export([run/2, run/3, run_ui/2, run_ui/3]).
-export([frac/2, drivable/2, shorten/1, priv_dir/0]).  % for the renderers
-export([widgets/1, rgb565/1, hue/1, label_of/1]).   % tests, introspection
-export([plots/1, eng/2, period/0, keep/2, rows/1, rows/3]). % tests
-export([looks/1, colour/3, warn_annotations/1]).    % tests, introspection

-include("candid.hrl").
-include_lib("kernel/include/file.hrl").

-define(PERIOD,    100).   % ms between cycles -- the DEFAULT, see period/0
%% What the tick rate may be set to, from the bar. 100 ms was chosen for lamps;
%% a plot wants a good deal more than ten samples a second, and a program with
%% a 2 s sweep gives twenty points at 100 ms. The top of the range is honest
%% about what it costs: every tick is a /commit plus one cast per plot.
-define(PERIODS,   [10, 25, 50, 100, 250]).
-define(VIEWS, [{"trace", ["hide", "show"]},
		{"code",  ["hide", "ladder", "code"]},
		{"theme", ["dark", "light"]}]).
-define(PHOSPHOR, "#5f9").  % the beam, when the annotation names no colour
-define(PERSIST,  0.90).           % how much of the last frame survives 100 ms
-define(BEAM_W,   1.6).            % px, line width of the beam
%% The kinds that show a number, and so take unit, scale, min and max.
-define(IS_NUMERIC(K), (K =:= slider orelse K =:= dial orelse K =:= invalue
			orelse K =:= meter orelse K =:= value
			orelse K =:= plot orelse K =:= plotin)).

%% The browser panel: wse's websocket and a web server for the page.
start() -> start(1234, 8080).

start(WsPort, HttpPort) -> candid_wse:start(WsPort, HttpPort).

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

%% wse's entry: the page calls Wse.start('candid', 'run', [Where, ...]).
run(Ws, Where) ->
    run(Ws, Where, default_file()).

run(Ws, Where, File) ->
    run_ui({candid_wse, Ws}, Where, File).

%% Any renderer's entry, U = {Module, Handle}: candid_wx calls this from the
%% process that owns its window.
run_ui(U, Where) ->
    run_ui(U, Where, default_file()).

run_ui(U, Where, File) ->
    %% The log and the chat, when ellm is there: processes of their own, so
    %% they live through every rebuild below. The log first: it is this
    %% process's group leader from here on, what it prints is kept.
    Log = candid_log:start(log_ui(U)),
    Chat = csp_chat:start(chat_ui(U), #{root => root(), exe => csp_exe(),
				       demo_dir => work_dir()}),
    render(U, Where, File, #{chat => Chat, log => Log}).

%% Also the restart path: picking another file in the chooser comes back here,
%% so the whole panel is rebuilt from that file's declarations.
%% Side is #{chat, log}, the two that outlive it.
render(U, Where, File, Side) ->
    candid_log:add(maps:get(log, Side), note, "--- " ++ shorten(File)),
    Root = ui(U, clear, [Where]),
    case candyspeak:parse(File) of
	{ok, Ast} ->
	    build(U, Where, Root, File, widgets(Ast), Ast, Side);
	_Error ->
	    %% candyspeak said why, on this process's output: in the log.
	    {SelId, _Run} = ui(U, chooser, [Root, bar(File, Side)]),
	    ui(U, message, [Root, io_lib:format("~n~s cannot be parsed, "
						"the log says why",
						[shorten(File)])]),
	    candid_log:show(maps:get(log, Side)),
	    wait_for_pick(U, Where, Side, SelId)
    end.

side(S) -> maps:with([chat, log], S).

%% The renderer's function F on its handle.
ui({M, H}, F, A) -> apply(M, F, [H | A]).

%% The code view's and the chat pane's renderers, on the same handle.
code_ui({M, H}) -> {M:code_view(), H}.
chat_ui({M, H}) -> {M:chat_view(), H}.
log_ui({M, H}) -> {M:log_view(), H}.

%% What the bar is built from.
bar(File, #{chat := Chat}) ->
    #{file => File, files => available(File), target => target_text(),
      period => period(), periods => ?PERIODS, views => ?VIEWS,
      chat => Chat =/= undefined}.

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

%% The inputs pulled up, named as widgets/1 names them: a button to ground,
%% 1 while nobody presses it.
pullups(Ast) ->
    {Main, Mods} = csp_code:split(Ast),
    P = fun(Ds) -> [N || {digital, _, {'WORD', _, N}, scalar, _, Opts, _} <- Ds,
			 proplists:get_value(dir, Opts, in) =:= in,
			 proplists:get_value(pull, Opts) =:= pullup]
	end,
    P(Main) ++ [O ++ "." ++ N
		|| {object, _, {'WORD', _, M}, {'WORD', _, O}, _} <- Main,
		   {ok, Body} <- [maps:find(M, Mods)], N <- P(Body)].

%% A pulled-up input's look says so: its widget sends 0 while held and shows
%% it lit when it is not at rest.
idle(Looks, Pulled) ->
    maps:map(fun(N, L) -> case lists:member(N, Pulled) of
			      true  -> L#{idle => 1};
			      false -> L
			  end
	     end, Looks).

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
    ann_fold(fun(_Target, _Kvs, _Old, _Ln) -> ok end, Ast).

%% The same, saying what is wrong with them: once per panel, from build/7.
warn_annotations(Ast) ->
    ann_fold(fun(Target, Kvs, Old, Ln) ->
		     Kv = maps:from_list(Kvs),
		     warn_unknown(Target, Kv, Ln),
		     warn_star(Target, Kv, Ln),
		     warn_repeat(Target, Kvs, Old, Ln)
	     end, Ast),
    ok.

ann_fold(Warn, Ast) ->
    lists:foldl(
      fun({annotate, Ln, {'WORD', _, "panel"}, {'WORD', _, Target}, Items}, M) ->
	      Kvs = [{K, ann_value(V)} || {{'WORD', _, K}, V} <- Items],
	      Old = maps:get(Target, M, #{}),
	      Warn(Target, Kvs, Old, Ln),
	      maps:put(Target, maps:merge(Old, maps:from_list(Kvs)), M);
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
		   "trace",
		   %% a keypad: its buttons and their grid, said on the group's own
		   %% name, and on a button the group it belongs to
		   "buttons", "layout", "group"]).

%% Keys that are about ONE signal: said on `*' they would make every widget
%% the same kind, or give them all one label. Never inherited from `*'.
-define(OWN_KEYS, ["kind", "label", "axis", "group"]).

%% Said twice -- on one line, or on a line before -- is most likely a line
%% copied and not changed: the signal it was meant for is left without it.
warn_repeat(Target, Kvs, Old, Ln) ->
    lists:foldl(
      fun({K, V}, Seen) ->
	      case maps:find(K, Seen) of
		  {ok, V} ->
		      io:format("panel: line ~w: ~s: ~s said again~n",
				[Ln, Target, kv_text(K, V)]);
		  {ok, V0} ->
		      io:format("panel: line ~w: ~s: ~s replaces ~s~n",
				[Ln, Target, kv_text(K, V), kv_text(K, V0)]);
		  error -> ok
	      end,
	      Seen#{K => V}
      end, Old, Kvs),
    ok.

kv_text(K, true) -> K;
kv_text(K, V) -> K ++ "=" ++ to_text(V).

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
    idle(looks(widgets(Ast), annotations(Ast), ranges(Ast)), pullups(Ast)).

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
%%% An #analog or a #field is unsigned unless it says `integer' -- counts, and
%%% bits of a frame. One that says it is SIGNED, and a plot that assumed
%%% 0..full-scale would draw the top half of the picture and clip everything
%%% below zero into the bottom edge: a sixteen-bit signed field fed from a
%%% socket is exactly that case. The annotation's min/max still wins.
ranges(Ast) ->
    lists:foldl(
      fun({analog, _Ln, {'WORD', _, N}, scalar, Res, Opts, _E}, M) ->
	      M#{N => swing(width(Res), Opts)};
	 ({field, _Ln, {'WORD', _, N}, Res, Opts, _Buf, Pos}, M) ->
	      M#{N => swing(field_width(Res, Pos), Opts)};
	 (_, M) -> M
      end, #{}, Ast).

swing(W, Opts) ->
    case W =:= 1 orelse proplists:get_value(type, Opts) =/= integer of
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

%%% ---------------------------------------------------------------- groups
%%%
%%% Widgets that belong together, said on the group's own name:
%%%
%%%     #annotate panel K1 group=keys
%%%     #annotate panel keys kind=keypad buttons="K1,K2,K3,K4" layout="2x2"
%%%
%%% buttons= gives the members and their order; group= on a widget puts it in
%%% too, after the listed ones. The group's KIND says how it is drawn:
%%%
%%%     keypad  the members are keys -- buttons only, push or toggle -- in a
%%%             grid, layout="RxC"; each named by its label, lit while held
%%%     (none)  the members as their own rows, together under the group's name
%%%
%%% That one finger presses one key at a time is the model's to know, not the
%%% panel's: `#annotate varp assume "[LTE 1](!K1, !K2, !K3, !K4)"'.
-define(GROUP_KINDS, ["keypad"]).

%% The rows the page shows: a widget, or a group in the place of its first
%% member.
rows(Ast) ->
    rows([W || W <- widgets(Ast), element(1, W) =/= pixel, not is_plot(W)],
	 looks(Ast), annotations(Ast)).

rows(Rest, Looks, Ann) ->
    Gs = groups(Rest, Ann),
    Of = maps:from_list([{N, Id} || {Id, Ns} <- Gs, N <- Ns]),
    {Out, _} =
	lists:foldl(
	  fun(W = {_, N, _}, {Acc, Done}) ->
		  case maps:find(N, Of) of
		      error -> {[{W, maps:get(N, Looks)} | Acc], Done};
		      {ok, Id} ->
			  case lists:member(Id, Done) of
			      true  -> {Acc, Done};
			      false -> {[group(Id, Gs, Rest, Looks, Ann) | Acc],
					[Id | Done]}
			  end
		  end
	  end, {[], []}, Rest),
    lists:reverse(Out).

%% [{Id, [Name]}]: every group named by buttons= or by a member's group=.
groups(Rest, Ann) ->
    Names = [N || {_, N, _} <- Rest],
    Ids = lists:usort([T || {T, #{"buttons" := _}} <- maps:to_list(Ann)] ++
		      [to_text(G) || N <- Names,
				     G <- [maps:get("group", maps:get(N, Ann, #{}), none)],
				     G =/= none]),
    [{Id, members(Id, Rest, Ann)} || Id <- Ids].

%% A keypad takes buttons only; a plain group anything that has a row.
members(Id, Rest, Ann) ->
    Kind = group_kind(Id, Ann),
    Can = [N || {K, N, _} <- Rest,
		Kind =/= "keypad" orelse K =:= push orelse K =:= toggle],
    Listed = [string:trim(B) || B <- string:lexemes(
				       to_text(maps:get("buttons",
							maps:get(Id, Ann, #{}), "")),
				       ",")],
    [io:format("panel: ~s: ~s left out, ~s~n", [Id, B, why_out(B, Rest)])
     || B <- Listed, not lists:member(B, Can)],
    [io:format("panel: ~s: ~s is listed in buttons= but says group=~s~n",
	       [Id, B, G])
     || B <- Listed, G <- [to_text(maps:get("group", maps:get(B, Ann, #{}),
					     Id))], G =/= Id],
    Grouped = [N || N <- Can,
		    to_text(maps:get("group", maps:get(N, Ann, #{}), none)) =:= Id],
    [N || N <- Listed ++ (Grouped -- Listed), lists:member(N, Can)].

why_out(B, Rest) ->
    case lists:keyfind(B, 2, Rest) of
	false -> "there is no such widget";
	{K, _, _} -> io_lib:format("it is a ~w and a keypad takes a push or "
				   "a toggle (kind=push)", [K])
    end.

group_kind(Id, Ann) ->
    case maps:get("kind", maps:get(Id, Ann, #{}), none) of
	none -> none;
	K0 ->
	    K = to_text(K0),
	    case lists:member(K, ?GROUP_KINDS) of
		true -> K;
		false ->
		    io:format("panel: ~s: kind=~s is not a kind of group (~s)~n",
			      [Id, K, string:join(?GROUP_KINDS, ", ")]),
		    none
	    end
    end.

%% {keypad, #{id, label, cols, keys}} or {group, #{id, label, rows}}:
%% layout="RxC" says a keypad's grid; without it the keys stand in one row.
group(Id, Gs, Rest, Looks, Ann) ->
    Kv = maps:get(Id, Ann, #{}),
    {Id, Ns} = lists:keyfind(Id, 1, Gs),
    Ms = [{W, maps:get(N, Looks)} || N <- Ns, W <- [lists:keyfind(N, 2, Rest)]],
    Label = to_text(maps:get("label", Kv, Id)),
    case group_kind(Id, Ann) of
	"keypad" ->
	    Cols = case string:lexemes(to_text(maps:get("layout", Kv, "")), "xX") of
		       [_R, C] -> case string:to_integer(C) of
				      {N, ""} when N > 0 -> N;
				      _ -> length(Ns)
				  end;
		       _ -> length(Ns)
		   end,
	    {keypad, #{id => Id, label => Label, cols => Cols, keys => Ms}};
	none ->
	    {group, #{id => Id, label => Label, rows => Ms}}
    end.

%%% ---------------------------------------------------------------- rendering

build(U, Where, Root, File, [], Ast, Side) ->
    %% Parsed fine, but nothing in it is a widget yet. Say which declarations
    %% it does have -- an empty panel otherwise looks like a failure.
    {SelId, _Run} = ui(U, chooser, [Root, bar(File, Side)]),
    ui(U, message, [Root, io_lib:format(
			    "nothing to show in ~s.~n~n"
			    "it declares: ~s~n~n"
			    "widgets come from #digital, #analog and #field; "
			    "variables and rules are not shown yet.",
			    [shorten(File), kinds(Ast)])]),
    wait_for_pick(U, Where, Side, SelId);
build(U, Where, Root, File, Widgets0, Ast, Side = #{chat := Chat, log := Log}) ->
    {SelId, Run} = ui(U, chooser, [Root, bar(File, Side)]),
    warn_annotations(Ast),
    Ann = annotations(Ast),
    Rng = ranges(Ast),
    Looks = idle(looks(Widgets0, Ann, Rng), pullups(Ast)),
    [warn_misplaced(W, Ann) || W <- Widgets0],
    %% hidden: no row, no trace, not a channel of any plot. csp still has it;
    %% the panel just does not show it.
    Widgets = [W || W = {_, N, _} <- Widgets0,
		    not maps:get(hidden, maps:get(N, Looks))],
    %% Two kinds do not get a row of their own: pixels are one strip and a
    %% plot's channels are one picture.
    {Pixels, Rest0} = lists:partition(fun({K, _, _}) -> K =:= pixel end,
				      Widgets),
    {Plots, Rest} = lists:partition(fun is_plot/1, Rest0),
    %% A plot channel still gets a TIME trace below. The XY picture says where
    %% the beam is and nothing about when it got there -- which of the two you
    %% need depends on what is wrong, so the panel shows both.
    %% trace=off leaves a signal out of it, and `* trace=off' leaves the trace
    %% out altogether -- a panel that is only there to drive a GUI has no use
    %% for a logic analyser underneath it.
    Ordered = [T || T = {_, N, _} <- Rest ++ Pixels ++ Plots,
		    maps:get(trace, maps:get(N, Looks))],
    P = ui(U, panel, [Root, #{rows => rows(Rest, Looks, Ann),
			      pixels => [{N, maps:get(N, Looks)}
					 || {_, N, _} <- Pixels],
			      plots => plot_groups(Plots, Ann, Rng),
			      traces => [maps:get(N, Looks)
					 || {_, N, _} <- Ordered]}]),
    {ok, Src} = candyspeak:parse(File, [sources]),
    Code = csp_code:new(code_ui(U), maps:get(code, P), {Src, File}, colours()),
    {ok, Link} = csp_link:open(target(), csp_exe(), [File]),
    erlang:send_after(period(), self(), tick),
    TraceBox = maps:get(trace_box, P),
    S0 = #{trace_box => TraceBox, code => Code, run => Run},
    S1 = lists:foldl(fun({K, V}, Si) -> view(U, Si, K, V) end, S0,
		     maps:to_list(views())),
    S2 = #{nodes  => maps:get(nodes, P),
	   traces => [{N, K, maps:get(N, Looks)} || {K, N, _} <- Ordered],
	   trace  => maps:get(trace, P),
	   plots  => maps:get(plots, P),
	   period => period(),
	   x      => 0,
	   last   => #{},
	   sel_id => SelId,
	   run    => Run,
	   mode   => run,
	   clock  => {0, undefined},
	   code   => maps:get(code, S1),
	   trace_box => TraceBox,
	   state_box => maps:get(state_box, P),
	   clock_box => maps:get(clock_box, P),
	   link_box => maps:get(link_box, P),
	   file   => File,
	   chat   => Chat,
	   log    => Log,
	   where  => Where},
    csp_chat:attach(Chat, chat_info(File)),
    loop(U, Link, start_mode(U, Link, S2)).

%% {mode, pause} in candid.config: start stopped, ready to step. Not a node: it
%% was running before we looked, and connecting is not a reason to stop it.
start_mode(U, Link, S) ->
    case {config(mode), target()} of
	{pause, {{local, _}, _}} -> control(U, Link, S, "mode=step");
	_ -> light_mode(U, S#{mode := run}), S#{mode := run}
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
retarget(U, Link, S, Text) ->
    case csp_link:target(Text) of
	{ok, T} ->
	    csp_link:close(Link),
	    flush(),
	    put(candid_target, T),
	    put(candid_target_text, Text),
	    {ok, Link1} = csp_link:open(T, csp_exe(), [maps:get(file, S)]),
	    {Link1, start_mode(U, Link1, S#{last := #{}})};
	{error, Why} ->
	    show_link(U, S, Why),
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

show_link(U, #{link_box := B}, Text) ->
    ui(U, status, [B, Text]);
show_link(_U, _S, _Text) ->
    ok.

%%% What is shown: the trace (hide | show), the code view (hide | ladder |
%%% code) and the theme (dark | light). Both views start hidden unless
%%% candid.config says otherwise:
%%%
%%%     {candid, [{trace, show}, {code, ladder}, {theme, light}]}
%%%
%%% Kept per browser session in the process dictionary, so picking another
%%% program keeps them -- render/3 starts the page over, and the choice is the
%%% person's, not the program's.

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

view(U, S, "trace", V) ->
    ui(U, trace_view, [maps:get(trace_box, S), V =:= "show"]),
    view_done(U, S, "trace", V);
view(U, S, "code", V) ->
    S1 = S#{code := csp_code:control(maps:get(code, S), V)},
    view_done(U, S1, "code", V);
view(U, S, "theme", V) ->
    ui(U, theme, [V]),
    view_done(U, S, "theme", V);
view(_U, S, _K, _V) ->
    S.

view_done(U, S, K, V) ->
    put(candid_views, maps:put(K, V, views())),
    ui(U, view_buttons, [maps:get(run, S), K, V]),
    S.

%% Where the program is: its cycle and its own clock, which stand still while
%% paused.
clock_text(Cycle, Prog) ->
    lists:flatten(io_lib:format("cycle ~w   time ~s", [Cycle, secs(Prog)])).

secs(undefined) -> "-";
secs(Ms)        -> io_lib:format("~.1f s", [Ms / 1000]).

%% Where V sits between min and max, 0.0..1.0, clamped: a reading outside the
%% range pins the needle rather than spinning it round the back.
frac(V, #{min := Min, max := Max}) ->
    (min(max(V, Min), Max) - Min) / max(Max - Min, 1).

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

%% Nothing to drive, so there is no csp and no tick -- just the chooser.
wait_for_pick(U, Where, Side, SelId) ->
    receive
	stop -> ok;
	Msg ->
	    case event(U, #{sel => SelId}, Msg) of
		{pick, File} -> render(U, Where, File, Side);
		{bar, "log=toggle"} -> candid_log:toggle(maps:get(log, Side)),
				       wait_for_pick(U, Where, Side, SelId);
		{bar, "chat=toggle"} -> csp_chat:toggle(maps:get(chat, Side)),
					wait_for_pick(U, Where, Side, SelId);
		closed       -> ok;
		_            -> wait_for_pick(U, Where, Side, SelId)
	    end
    end.

event({M, _H}, Ids, Msg) -> M:event(Ids, Msg).

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

loop(U, Link, S) ->
    receive
	{csp_state, _N, Vals} ->
	    loop(U, Link, update(U, S, Vals));

	{csp_fired, _N, Rules} ->
	    loop(U, Link,
		 S#{code := csp_code:fired(maps:get(code, S), Rules)});

	{csp_clock, N, Ms} ->
	    loop(U, Link, S#{clock := {N, Ms}});

	%% varp's answer to the code view's clear or solve.
	{csp_model, A} ->
	    loop(U, Link, code_do(U, Link, S,
				  csp_code:model(maps:get(code, S), A)));

	%% Draw on the TICK, not on the dump. csp only dumps what changed, so a
	%% trace driven by dumps stops moving as soon as the program settles --
	%% which is exactly when you are staring at it wondering why. Drawing
	%% here also means the x axis is wall time, not cycle number.
	%% The timer keeps arriving while stepping -- it just does not drive the
	%% program. Drawing still happens, so a held value stays visible as a
	%% flat line rather than the trace freezing mid-air.
	tick ->
	    show_clock(U, S),
	    S1 = (draw(U, S))#{code := csp_code:tick(maps:get(code, S))},
	    case maps:get(mode, S, run) of
		run  -> csp_link:tick(Link);
		step -> ok
	    end,
	    erlang:send_after(maps:get(period, S, ?PERIOD), self(), tick),
	    loop(U, Link, S1);

	{csp_link, Text} ->
	    show_link(U, S, Text),
	    candid_log:add(maps:get(log, S), link, Text),
	    loop(U, Link, S);

	%% What csp says besides the dumps: an error after a set, Paused ...
	{csp_out, Text} ->
	    candid_log:add(maps:get(log, S), csp, Text),
	    loop(U, Link, S);

	%% A node's program, listed off its image: the panel is rebuilt from it,
	%% so the code and the widgets are what RUNS there and not whatever
	%% file happened to be open. Once it shows that program this is a no-op,
	%% which is what keeps the reconnect after the rebuild from looping.
	{csp_program, Text} ->
	    File = node_file(target_text()),
	    Bin = unicode:characters_to_binary(Text),
	    case file:read_file(maps:get(file, S)) of
		{ok, Bin} ->
		    loop(U, Link, S);
		_ ->
		    ok = filelib:ensure_dir(File),
		    ok = file:write_file(File, Bin),
		    csp_link:close(Link),
		    flush(),
		    render(U, maps:get(where, S), File, side(S))
	    end;

	%% csp ended, or the node went away. The panel stays: another target
	%% can be typed in.
	{csp_exit, _Status} ->
	    loop(U, Link, S);

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
		    render(U, maps:get(where, S), File, side(S));
		{control, Tag, Reply} ->
		    From ! {Ref, Reply},
		    loop(U, Link, control(U, Link, S, Tag));
		Reply ->
		    From ! {Ref, Reply},
		    loop(U, Link, S)
	    end;

	stop -> csp_link:close(Link);

	%% Anything else is the renderer's: what the person did.
	Msg ->
	    act_ui(U, Link, S, event(U, ids(S), Msg))
    end.

%% The event ids the renderer tells the chooser, the bar and the code view
%% by: the bar's from a widget's by the id rather than by the payload, so a
%% signal called "step" could not be mistaken for the button.
ids(S) ->
    #{sel => maps:get(sel_id, S),
      run => maps:get(event, maps:get(run, S, #{}), undefined),
      code => case maps:get(code, S, undefined) of
		  #{event := Ce} -> Ce;
		  _ -> undefined
	      end}.

%% Another program was picked: drop this csp and rebuild from that file.
act_ui(U, Link, S, {pick, File}) ->
    csp_link:close(Link),
    flush(),
    render(U, maps:get(where, S), File, side(S));
%% run / pause / step, the target, the views: the bar.
act_ui(U, Link, S, {bar, "target=" ++ Text}) ->
    {Link1, S1} = retarget(U, Link, S, Text),
    csp_chat:attach(maps:get(chat, S1), chat_info(maps:get(file, S1))),
    loop(U, Link1, S1);
act_ui(U, Link, S, {bar, "log=toggle"}) ->
    candid_log:toggle(maps:get(log, S)),
    loop(U, Link, S);
act_ui(U, Link, S, {bar, "chat=toggle"}) ->
    csp_chat:toggle(maps:get(chat, S)),
    loop(U, Link, S);
act_ui(U, Link, S, {bar, Tag}) ->
    loop(U, Link, control(U, Link, S, Tag));
%% ladder / code, from the code view's own bar.
act_ui(U, Link, S, {code, Tag}) ->
    loop(U, Link, code_do(U, Link, S,
			  csp_code:control(maps:get(code, S), Tag)));
%% A widget. A switch sends its bare name: we do not track its state
%% ourselves but toggle against what csp last told us, so the button can
%% never disagree with the program. Anything else sends Name=Value.
act_ui(U, Link, S, {widget, Data}) ->
    set_widget(Link, S, Data),
    loop(U, Link, S);
%% Several at once: an XY plot dragged sets both axes from one move.
act_ui(U, Link, S, {widgets, Ds}) ->
    [set_widget(Link, S, D) || D <- Ds],
    loop(U, Link, S);
act_ui(_U, Link, _S, closed) ->
    csp_link:close(Link);
act_ui(U, Link, S, none) ->
    loop(U, Link, S).

set_widget(Link, S, Data) ->
    case string:split(Data, "=") of
	[Name, Val] ->
	    csp_link:set(Link, Name, Val);
	[Name] ->
	    Cur = maps:get(Name, maps:get(last, S), 0),
	    csp_link:set(Link, Name, case Cur of 0 -> 1; _ -> 0 end)
    end.

%% What the code view asked csp for: a replayed trace's reset, inputs and
%% steps. A replay runs paused, so the bar says so.
code_do(U, Link, S, Code0) ->
    {Acts, Code} = csp_code:actions(Code0),
    lists:foldl(fun(A, Si) -> act(U, Link, Si, A) end, S#{code := Code}, Acts).

act(U, Link, S = #{mode := run}, pause) -> control(U, Link, S, "mode=step");
act(_U, _Link, S, pause)                -> S;
act(_U, Link, S, reset)                 -> csp_link:reset(Link), S;
act(_U, Link, S, {clock, Ms})           -> csp_link:clock(Link, Ms), S;
act(_U, _Link, S, {frame, Id, Bytes})   -> send_frame(Id, Bytes), S;
act(_U, Link, S, {set, N, V})           -> csp_link:set(Link, N, V), S;
act(_U, Link, S, step)                  -> csp_link:step(Link), S.

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
show_clock(U, #{clock_box := B, clock := {N, Ms}}) ->
    T = clock_text(N, Ms),
    case get(candid_clock) of
	T -> ok;
	_ -> put(candid_clock, T),
	     ui(U, status, [B, T])
    end;
show_clock(_U, _S) ->
    ok.

%% run: let the program go. step: freeze it, so values set from widgets wait for
%% a /step and are committed together.
control(U, Link, S, "mode=run") ->
    csp_link:resume(Link),
    S1 = S#{mode := run},
    light_mode(U, S1),
    S1;
control(U, Link, S, "mode=step") ->
    csp_link:pause(Link),
    S1 = S#{mode := step},
    light_mode(U, S1),
    S1;
control(_U, Link, S, "step=1") ->
    %% Only meaningful while stopped; in run mode the program is already going
    %% and a step would be indistinguishable from the tick.
    case maps:get(mode, S, run) of
	step -> csp_link:step(Link, 1);
	run  -> ok
    end,
    S;
%% A new tick takes effect on the NEXT one: the timer already in flight is left
%% to arrive, so changing the rate cannot drop a tick or run two at once.
control(U, _Link, S, "trace=" ++ V) -> view(U, S, "trace", V);
control(U, _Link, S, "code=" ++ V)  -> view(U, S, "code", V);
control(U, _Link, S, "theme=" ++ V) -> view(U, S, "theme", V);
control(_U, _Link, S, "period=" ++ Ms) ->
    case string:to_integer(Ms) of
	{N, _} when is_integer(N), N >= 5, N =< 10000 -> S#{period := N};
	_                                             -> S
    end;
control(_U, _Link, S, _Other) ->
    S.

%% Which of the three is in force, so the bar says where you are.
light_mode(U, S) ->
    ui(U, mode, [maps:get(run, S), maps:get(mode, S, run) =:= step]).

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
update(U, S, Vals) ->
    Last = maps:get(last, S),
    paint(U, S, [{N, V} || {N, V} <- Vals,
			   maps:get(N, Last, undefined) =/= V]),
    Last1 = maps:merge(Last, maps:from_list(Vals)),
    S#{last := Last1,
       code := csp_code:refresh(maps:get(code, S, undefined), Last1)}.

paint(U, S, Vals) ->
    Nodes = maps:get(nodes, S),
    lists:foreach(fun({Name, V}) -> ui(U, paint, [maps:find(Name, Nodes), V]) end,
		  Vals).

%% One column per tick, drawn incrementally: a dot per trace beats redrawing
%% the whole trace.
draw(U, S) ->
    X = maps:get(x, S),
    Trace = maps:get(trace, S),
    Last = maps:get(last, S),
    Ms = maps:get(period, S, ?PERIOD),
    Plots = [plot_tick(U, G, Last, Ms) || G <- maps:get(plots, S)],
    if Trace =:= none ->                    % trace=off on `*'
	    S#{plots := Plots};
       X >= ?TRACE_W ->
	    %% wrap, right of the labels
	    ui(U, trace_clear, [Trace]),
	    trace_column(U, S#{x := 0, plots := Plots});
       true ->
	    trace_column(U, S#{plots := Plots})
    end.

trace_column(U, S = #{x := X, trace := Trace, last := Last}) ->
    {_, Items} =
	lists:foldl(
	  fun({Name, Kind, Look}, {Row, Acc}) ->
		  V = maps:get(Name, Last, 0),
		  {Y, Col} = sample(Row * ?ROW_H + 4, Kind, V, Look),
		  {Row + 1, Acc ++ [?GUTTER + X, Y, Col]}
	  end, {0, []}, maps:get(traces, S)),
    ui(U, trace_column, [Trace, Items]),
    S#{x := X + ?STEP}.

%% The beam moves on the TICK, like the trace and for the same reason: csp dumps
%% only what changed, so a plot driven by dumps stops the moment the program
%% settles -- and a settled XY reading is still a reading. Drawing here also
%% means the afterglow decays in wall time, which is what makes it read as one.
plot_tick(U, G = #{x := undefined}, Last, Ms) ->
    %% No x channel, so the beam sweeps: time along the bottom. See pick_x/3.
    Sw = maps:get(sweep, G),
    G1 = cast_plot(U, G, ?PAD + (Sw rem (?PLOT_W - 2 * ?PAD)), Last, Ms),
    G1#{sweep := Sw + 2};
plot_tick(U, G = #{x := X}, Last, Ms) ->
    cast_plot(U, G, px(val(X, Last), X), Last, Ms).

cast_plot(U, G = #{ys := Ys, persist := P, prev := Prev}, Px, Last, Ms) ->
    {Items, Prev1} =
	lists:foldl(
	  fun(M, {Acc, Pm}) ->
		  Name = maps:get(name, M),
		  Py = py(val(M, Last), M),
		  {X0, Y0} = seg(maps:get(Name, Pm, none), Px),
		  {Acc ++ [X0, Y0, Px, Py, maps:get(colour, M)],
		   Pm#{Name => {Px, Py}}}
	  end, {[], Prev}, Ys),
    ui(U, plot, [G, keep(P, Ms), Items]),
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
    Found = lists:append([csp_in(D) || D <- lists:usort([demo_dir(), work_dir()])]
			 ++ [csp_in(examples_dir())]),
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

%%% -------------------------------------------------------------------- paths

%% candid's own files are found from where its beam is -- priv/, where
%% priv/demo is a link to demo/ in a checkout and the copy in a packaged
%% system -- candyspeak's (the examples, csp, the manual) from csp_tools:dir/0.
%% Overridable, because when it does not hold the failure is an enoent on a
%% path nobody typed.
demo_dir() ->
    case os:getenv("CANDID_DEMO") of
	false -> filename:join(priv_dir(), "demo");
	Dir   -> Dir
    end.

%% Where a new program goes -- the chat's: demo/ when it can be written, and
%% ~/candid otherwise, which is what a packaged system (an AppImage is read
%% only) gets.
work_dir() ->
    D = demo_dir(),
    case file:read_file_info(D) of
	{ok, #file_info{access = read_write}} -> D;
	_ ->
	    W = filename:join(os:getenv("HOME", "."), "candid"),
	    ok = filelib:ensure_dir(filename:join(W, "x")),
	    W
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

%% absname first: with a relative -pa, code:which/1 answers a relative path
%% and every dirname above would climb out of the wrong tree.
base() ->
    filename:dirname(filename:dirname(filename:absname(code:which(?MODULE)))).

%% candyspeak's files: the tree's, or what came along with csp_tools.
root() ->
    case os:getenv("CANDYSPEAK") of
	false -> csp_tools:dir();
	Dir   -> Dir
    end.

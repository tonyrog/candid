%% Drives the panel against the recording wse and a real csp process.
%%
%%   make test
%%
%% Checks the three things the loop is for: that the widgets are DERIVED from
%% the declarations, that a click reaches csp and comes back as a lit lamp, and
%% that the trace keeps sampling when nothing changes.

-module(panel_test).

-export([run/0]).
-export([logger/1]).

-define(SETTLE, 600).

run() ->
    %% No chat: the stub numbers events in the order they are made, and the
    %% checks below know the panel's by number. chat_checks/0 has its own.
    _ = application:load(candid),
    application:set_env(candid, chat, off),
    register(wse_log, spawn(?MODULE, logger, [[]])),
    File = filename:join([code:lib_dir(), "..", "demo", "gate.csp"]),
    Demo = case filelib:is_regular(File) of
	       true  -> File;
	       false -> "demo/gate.csp"
	   end,
    {ok, Ast} = candyspeak:parse(Demo),

    %% 1. derivation
    Widgets = candid:widgets(Ast),
    expect("widgets derived from declarations",
	   Widgets =:= [{toggle, "Button", 1}, {lamp, "Led", 1}], Widgets),

    P = track_panel(spawn(fun() -> candid:run(fake_ws, "panel", Demo) end)),
    timer:sleep(?SETTLE),
    Before = calls(),

    %% 2. a click reaches csp and comes back
    P ! {notify, 1, local, "Button"},
    timer:sleep(?SETTLE),
    After = calls(),
    %% Led has no colour in its name, so it is red -- see candid:hue/1
    Lit = [X || X <- After -- Before, string:find(X, "#f44") =/= nomatch],
    expect("click lights the lamp", Lit =/= [], length(Lit)),

    %% 3. releasing it puts the lamp out again -- demo/gate.csp assigns every
    %%    cycle, so Led follows Button down. (demo/latch.csp does not, on
    %%    purpose: a guarded rule does nothing when its guard is false.)
    Mid = calls(),
    P ! {notify, 1, local, "Button"},
    timer:sleep(?SETTLE),
    Out = [X || X <- calls() -- Mid, string:find(X, "#251515") =/= nomatch],
    expect("releasing it puts the lamp out", Out =/= [], length(Out)),

    %% 4. the trace keeps moving after the program settles
    Quiet0 = length(samples(calls())),
    timer:sleep(?SETTLE),
    Quiet1 = length(samples(calls())),
    expect("trace samples while nothing changes", Quiet1 > Quiet0,
	   {Quiet0, Quiet1}),

    %% 5. picking another program tears the panel down and rebuilds it from
    %%    that file. demo/latch.csp has the same two pins, so the widgets match
    %%    but the behaviour does not: a guarded rule leaves the lamp lit.
    SelId = first_event(),
    Before5 = calls(),
    P ! {notify, SelId, local, latch_file()},
    timer:sleep(?SETTLE),
    New = calls() -- Before5,
    expect("picking another file rebuilds the panel",
	   [X || X <- New, string:find(X, "createElement select") =/= nomatch]
	   =/= [], length(New)),

    P ! stop,
    timer:sleep(200),

    %% 6. analog: the width comes from the declaration, and port 9 is the CPX
    %%    pixel strip rather than a magnitude.
    analog_checks(),
    node_checks(),
    uart_checks(),
    chat_checks(),

    %% 6b. the lamp colour comes from the name, and an unlabelled one is red
    Hues = [{N, element(1, candid:hue(N))}
	    || N <- ["Red","Yellow","Green","Led","Blue","GronLampa"]],
    expect("lamp colour taken from the name",
	   Hues =:= [{"Red","#f44"}, {"Yellow","#fd3"}, {"Green","#3f3"},
		     {"Led","#f44"}, {"Blue","#5af"}, {"GronLampa","#3f3"}],
	   Hues),

    %% 6c. an array declaration is one widget per element, and the dump's
    %%     unnamed entries are numbered back onto it. cpx_rotate.csp declares
    %%     its strip as `#analog P[10]:16` and had no pixels at all before.
    array_check(),

    %% 6d. home.csp's invariants actually hold. Both of these failed in the
    %%     first draft: the window check sat outside any #in block, so it ran
    %%     only in INIT and NORMAL and never in Home.
    home_checks(),

    %% 6e. the __Colour suffix names a colour outright and is hidden from the
    %%     label. An unknown suffix is left alone rather than silently eaten.
    Sfx = [{candid:label_of(N), element(1, candid:hue(N))}
	   || N <- ["Heater__Orange", "BathFan__Blue", "Siren__Red",
		    "Motor__Bogus"]],
    expect("__Colour suffix sets the colour and hides itself",
	   Sfx =:= [{"Heater","#f92"}, {"BathFan","#5af"},
		    {"Siren","#f44"}, {"Motor__Bogus","#f44"}], Sfx),

    %% 6f. the varp generator names states, so a gate reads `St == Home' rather
    %%     than `St == 3' -- unless the name is taken, in which case the number
    %%     stays, because defining it twice would shadow the other one.
    varp_gen_check(),
    varp_model_check(),
    varp_prop_check(),
    code_view_check(),

    %% 6g. #annotate picks the widget where the declaration cannot. Nothing in
    %%     `#digital NightButton in 6' says momentary or latching, and it should
    %%     not -- presentation is not in the language.
    annotate_check(),

    %% 6h. the XY plot: two channels that share an id are one picture, and the
    %%     canvas drives both of them.
    plot_check(),

    %% 6i. a #field is a window into a #buffer, which is what lets a socket
    %%     drive a plot.
    field_check(),

    %% 6j. the glass and the clock: shape=round, and a tick that can be changed
    %%     without the afterglow changing length.
    crt_check(),

    %% 6k. label, hidden, color, unit, scale, min and max mean the same thing
    %%     on every widget that can show them.
    look_check(),

    %% 7. a program with no inputs at all still runs -- traffic.csp is driven
    %%    by its own timer, so the lamps must change with nobody touching
    %%    anything. That also proves the tick actually advances csp.
    traffic_check(),
    halt(0).

%% demo/xy.csp: two analog inputs, one plot. The things that can go wrong here
%% are the grouping (two declarations, one widget) and the steering (one pointer,
%% two values) -- so both are checked against a real csp rather than by eye.
plot_check() ->
    {ok, A} = candyspeak:parse("demo/xy.csp"),
    W = candid:widgets(A),
    expect("kind=plot on an analog in becomes a steerable plot channel",
	   W =:= [{plotin, "xin", 10}, {plotin, "yin", 10}], W),

    [G] = candid:plots(A),
    #{id := Id, x := X, ys := Ys} = G,
    expect("channels sharing an id are one plot, x and y as annotated",
	   Id =:= "plot1" andalso maps:get(name, X) =:= "xin" andalso
	   [maps:get(name, M) || M <- Ys] =:= ["yin"],
	   {Id, maps:get(name, X), [maps:get(name, M) || M <- Ys]}),

    %% The range is the declared width unless the annotation narrows it, and
    %% `scale'/`unit' are what a count means in the world -- 1023 counts of a
    %% 10-bit input at 0.000976 is one volt, which is the number on the knob.
    expect("the channel's range comes from the declaration",
	   maps:get(min, X) =:= 0 andalso maps:get(max, X) =:= 1023,
	   {maps:get(min, X), maps:get(max, X)}),
    Eng = lists:flatten(candid:eng(600, X)),
    expect("a scaled channel reads in engineering units",
	   Eng =:= "600  0.586 ms", Eng),
    Plain = lists:flatten(candid:eng(600, #{scale => 1, unit => ""})),
    expect("an unscaled channel is just the count", Plain =:= "600", Plain),

    %% No axis given: the first channel goes across and the rest up. A guess,
    %% and it says so on stdout -- but it must be THIS guess, because a plot
    %% drawn the other way round is a picture of something else.
    Bare = "#analog a:8 in unsigned 0\n#analog b:8 in unsigned 1\n"
	   "#annotate panel a kind=plot\n#annotate panel b kind=plot\n",
    Tmp = "/tmp/csp_plot_bare.csp",
    ok = file:write_file(Tmp, Bare),
    {ok, A2} = candyspeak:parse(Tmp),
    [G2] = candid:plots(A2),
    expect("no axis: the first channel is x, the rest y",
	   maps:get(name, maps:get(x, G2)) =:= "a" andalso
	   [maps:get(name, M) || M <- maps:get(ys, G2)] =:= ["b"],
	   G2),

    %% Only y channels: there is nothing to put across, so the beam sweeps and
    %% the plot degrades to an ordinary scope rather than drawing a vertical
    %% line and calling it an XY picture.
    OnlyY = "#analog c:8 in unsigned 0\n"
	    "#annotate panel c kind=plot axis=y\n",
    Tmp2 = "/tmp/csp_plot_y.csp",
    ok = file:write_file(Tmp2, OnlyY),
    {ok, A3} = candyspeak:parse(Tmp2),
    [G3] = candid:plots(A3),
    expect("a plot with no x channel sweeps instead",
	   maps:get(x, G3) =:= undefined andalso
	   [maps:get(name, M) || M <- maps:get(ys, G3)] =:= ["c"], G3),

    %% ...and the whole loop: the canvas drives csp, and csp comes back.
    flush(),
    P = track_panel(spawn(fun() -> candid:run(fake_ws, "panel", "demo/xy.csp")
			  end)),
    timer:sleep(?SETTLE),
    Id2 = plot_event(),
    Before = calls(),
    %% What the canvas handler sends: one notify per axis, same wire format a
    %% slider uses. Both land before the next tick commits them.
    P ! {notify, Id2, local, "xin=600"},
    P ! {notify, Id2, local, "yin=300"},
    timer:sleep(?SETTLE),
    New = calls() -- Before,
    expect("steering the canvas sets both channels in csp",
	   [X2 || X2 <- New, string:find(X2, "600  0.586 ms") =/= nomatch]
	   =/= [] andalso
	   [X3 || X3 <- New, string:find(X3, "300  0.293 V") =/= nomatch]
	   =/= [],
	   [X4 || X4 <- New, string:find(X4, "textContent") =/= nomatch]),
    expect("the beam is drawn with an afterglow decay each tick",
	   [K || {K, _} <- plot_keeps(New), K > 0.0, K < 1.0] =/= [],
	   length(New)),

    %% A SEGMENT, not a dot: five numbers per channel, and the pair at the
    %% front is where the beam was. Ten samples a second is a dotted line as
    %% dots and the signal as segments.
    Casts = plot_casts(calls()),
    expect("the beam is drawn as a segment from the last sample",
	   Casts =/= [] andalso lists:all(fun(C) -> length(C) =:= 5 end, Casts)
	   andalso [C || C <- Casts, hd(C) >= 0] =/= [],
	   lists:sublist(Casts, 3)),
    expect("the first sample has nothing to draw a segment from",
	   hd(hd(Casts)) =:= -1, hd(Casts)),

    %% ...and a jump of more than half the width across is a RETRACE, blanked
    %% the way a scope blanks it: without this a sweep draws a bright diagonal
    %% back over its own picture every cycle.
    P ! {notify, Id2, local, "xin=1000"},
    timer:sleep(?SETTLE),
    Mid2 = calls(),
    P ! {notify, Id2, local, "xin=20"},
    timer:sleep(?SETTLE),
    Jumped = plot_casts(calls() -- Mid2),
    expect("a jump across the picture is a retrace, not a line",
	   [C || C <- Jumped, hd(C) < 0] =/= [], Jumped),
    P ! stop,
    timer:sleep(300).

%% The arrays handed to the plot painter, oldest first. Scanned back into terms
%% rather than matched as text: the point of the check is the NUMBERS.
plot_casts(L) ->
    [Items || {_Keep, Items} <- plot_keeps(L)].

%% {Keep, Items} per plot cast: the decay and the beam it drew.
plot_keeps(L) ->
    [KI || X <- L,
	   Rest <- [string:prefix(X, "ASYNC cast call ")], Rest =/= nomatch,
	   KI <- [cast_array(Rest)], KI =/= none].

cast_array(Text) ->
    case erl_scan:string(Text ++ ".") of
	{ok, Toks, _} ->
	    case erl_parse:parse_term(Toks) of
		{ok, [null, _Ctx, _W, _H, Keep, _Round, _Clip, _Beam, _Dot,
		      _Glow, _Step, {array, Items}]} ->
		    {Keep, Items};
		_ -> none
	    end;
	_ -> none
    end.

%% The two things that only matter because the panel is looked at: a round face
%% and a tick you can turn up. Both have one trap each -- an unknown shape must
%% not silently draw something, and a faster tick must not wash the trail away.
crt_check() ->
    Src = "#analog x:10 in unsigned 0\n#analog y:10 in unsigned 1\n"
	  "#annotate panel x kind=plot axis=x id=crt shape=round persist=0.95\n"
	  "#annotate panel y kind=plot axis=y id=crt\n",
    Tmp = "/tmp/csp_crt.csp",
    ok = file:write_file(Tmp, Src),
    {ok, A} = candyspeak:parse(Tmp),
    [G] = candid:plots(A),
    %% ...and said on ONE channel: the glass and the phosphor belong to the
    %% picture, so they must not have to be repeated per channel.
    expect("shape=round and persist= are settings of the picture",
	   maps:get(round, G) =:= true andalso maps:get(persist, G) =:= 0.95,
	   {maps:get(round, G), maps:get(persist, G)}),

    %% A fixture and not demo/xy.csp: the DEFAULT is what is being checked, and
    %% hanging that on a demo file means the suite breaks the day someone makes
    %% that demo round -- which is a thing they should be free to do.
    Plain = "#analog p:10 in unsigned 0\n"
	    "#annotate panel p kind=plot axis=y id=flat\n",
    TmpP = "/tmp/csp_crt_plain.csp",
    ok = file:write_file(TmpP, Plain),
    {ok, B} = candyspeak:parse(TmpP),
    [G2] = candid:plots(B),
    expect("a plot that says nothing is square",
	   maps:get(round, G2) =:= false, maps:get(round, G2)),

    Bad = "#analog z:10 in unsigned 0\n"
	  "#annotate panel z kind=plot axis=y id=q shape=oval\n",
    Tmp2 = "/tmp/csp_crt_bad.csp",
    ok = file:write_file(Tmp2, Bad),
    {ok, A3} = candyspeak:parse(Tmp2),
    [G3] = candid:plots(A3),
    expect("a shape nobody knows is refused, not guessed at",
	   maps:get(round, G3) =:= false, maps:get(round, G3)),

    %% The afterglow is a TIME. The same persist= at a four times faster tick
    %% has to wash four times more gently, or asking for a faster tick would
    %% take the trail away -- which is when you most want it.
    Slow = candid:keep(0.9, 100),
    Fast = candid:keep(0.9, 25),
    expect("persistence is a time, not a number of frames",
	   abs(Slow - 0.9) < 0.001 andalso Fast > Slow andalso
	   abs(math:pow(Fast, 4) - Slow) < 0.001, {Slow, Fast}),
    expect("persist=0 is no trail, and it never holds forever",
	   candid:keep(0, 100) == 0.0 andalso candid:keep(1, 100) < 1.0,
	   {candid:keep(0, 100), candid:keep(1, 100)}),

    %% The decay reaches the background. The browser does it, so the test is
    %% the same arithmetic: a wash of alpha 0.1 stalls five levels short; a
    %% truncated multiply cannot stall, because it always takes at least one.
    Wash = decay(fun(D) -> D - round(0.1 * D) end, 60),
    Trunc = decay(fun(D) -> trunc(D * 0.9) end, 60),
    expect("the afterglow decays all the way to the background",
	   Wash > 0 andalso Trunc =:= 0, {Wash, Trunc}),

    %% The beam: one setting of the picture, said once, like the glass.
    Thin = "#analog x:10 in unsigned 0\n#analog y:10 in unsigned 1\n"
	   "#annotate panel x kind=plot axis=x id=t beam=1 dot=0 glow=off "
	   "line=step\n#annotate panel y kind=plot axis=y id=t\n",
    TmpT = "/tmp/csp_thin.csp",
    ok = file:write_file(TmpT, Thin),
    {ok, AT} = candyspeak:parse(TmpT),
    [GT] = candid:plots(AT),
    [GP] = candid:plots(A),
    expect("beam= dot= glow= line= set the beam",
	   maps:with([beam, dot, glow, step], GT) =:=
	   #{beam => 1, dot => 0, glow => false, step => true} andalso
	   maps:with([beam, dot, glow, step], GP) =:=
	   #{beam => 1.6, dot => 1.6 * 1.5, glow => true, step => false},
	   {maps:with([beam, dot, glow, step], GT),
	    maps:with([beam, dot, glow, step], GP)}),

    %% And the starting tick comes from the environment, with garbage refused
    %% rather than taken as zero -- a zero would be a tick with no wait in it.
    os:putenv("CANDID_PERIOD", "25"),
    P25 = candid:period(),
    os:putenv("CANDID_PERIOD", "fort"),
    Pbad = candid:period(),
    os:unsetenv("CANDID_PERIOD"),
    expect("CANDID_PERIOD sets the tick, nonsense does not",
	   P25 =:= 25 andalso Pbad =:= 100, {P25, Pbad}),

    %% The clip follows the glass unless told otherwise. Both ways round, since
    %% the default is the interesting part: a round face that paints into its
    %% own corners is a square picture behind a round bezel.
    expect("a round face clips, a square one does not",
	   maps:get(clip, G) =:= true andalso maps:get(clip, G2) =:= false,
	   {maps:get(clip, G), maps:get(clip, G2)}),
    expect("clip= overrides the glass both ways",
	   clip_of("shape=round clip=off") =:= false andalso
	   clip_of("shape=square clip=on") =:= true,
	   {clip_of("shape=round clip=off"), clip_of("shape=square clip=on")}),
    %% ...and a value nobody knows falls back to the glass rather than picking
    %% one: a silent guess here is a picture with a piece missing.
    expect("a clip nobody knows falls back to the glass",
	   clip_of("shape=round clip=sometimes") =:= true andalso
	   clip_of("shape=square clip=sometimes") =:= false,
	   {clip_of("shape=round clip=sometimes"),
	    clip_of("shape=square clip=sometimes")}).

%% The look: one reading of the generic keys for every kind. Each of these was
%% either plot-only or accepted and then ignored before.
look_check() ->
    Src = "#digital Lamp out 8\n"
	  "#digital Btn in 2\n"
	  "#analog  Temp:10 in 0\n"
	  "#analog  Level:8 out unsigned 1\n"
	  "#analog  Gone:8 out unsigned 2\n"
	  "#analog  Swing:10 out 3\n"
	  "#annotate panel Lamp color=amber label=\"Kök\"\n"
	  "#annotate panel Btn  color=\"#0f0\" kind=push\n"
	  "#annotate panel Temp kind=dial min=-200 max=0x3FF scale=0.1 "
	  "unit=\"°C\"\n"
	  "#annotate panel Level color=0x8040ff\n"
	  "#annotate panel Gone hidden\n",
    Tmp = "/tmp/csp_look.csp",
    ok = file:write_file(Tmp, Src),
    {ok, A} = candyspeak:parse(Tmp),
    L = candid:looks(A),
    Get = fun(N, K) -> maps:get(K, maps:get(N, L)) end,
    expect("color= names a lamp's colour, label= its label",
	   Get("Lamp", colour) =:= {"#fb2", "#251c0c"} andalso
	   Get("Lamp", label) =:= "K\x{f6}k",
	   {Get("Lamp", colour), Get("Lamp", label)}),
    expect("color= takes #rgb and 0xRRGGBB, and dims the unlit one",
	   Get("Btn", colour) =:= {"#00ff00", "rgb(0,36,0)"} andalso
	   element(1, Get("Level", colour)) =:= "#8040ff",
	   {Get("Btn", colour), Get("Level", colour)}),
    expect("min= may be negative and max= hex",
	   {Get("Temp", min), Get("Temp", max)} =:= {-200, 1023},
	   {Get("Temp", min), Get("Temp", max)}),
    expect("a signed analog swings both ways without being told",
	   {Get("Swing", min), Get("Swing", max)} =:= {-512, 511} andalso
	   {Get("Level", min), Get("Level", max)} =:= {0, 255},
	   {Get("Swing", min), Get("Swing", max)}),
    Eng = lists:flatten(candid:eng(215, maps:get("Temp", L))),
    expect("scale= and unit= on a dial, not only on a plot",
	   Eng =:= "215  21.500 \x{b0}C", Eng),
    expect("hidden alone hides, nothing else does",
	   Get("Gone", hidden) =:= true andalso Get("Lamp", hidden) =:= false,
	   {Get("Gone", hidden), Get("Lamp", hidden)}),
    expect("a colour nobody knows falls back to the default",
	   candid:colour("X", lamp, #{"color" => "mauve"}) =:=
	   candid:hue("X"), ok),

    %% ...and through the rendering: the hidden one has no row, and the lamp
    %% lights in the colour it was given rather than the one its name implies.
    flush(),
    P = track_panel(spawn(fun() -> candid:run(fake_ws, "panel", Tmp) end)),
    timer:sleep(?SETTLE),
    C = calls(),
    expect("a hidden widget gets no row",
	   [X || X <- C, string:find(X, "Gone") =/= nomatch] =:= [], ok),
    expect("the label is what the row says",
	   [X || X <- C, string:find(X, "createTextNode K") =/= nomatch] =/= [],
	   [X || X <- C, string:find(X, "createTextNode") =/= nomatch]),
    P ! stop,
    timer:sleep(300),
    trace_check().

%% The logic trace: labelled rows, trace=off per signal, and `* trace=off' for
%% a panel that is only a GUI.
trace_check() ->
    Src = "#digital Lamp out 8\n#digital Quiet out 9\n#digital Btn in 2\n"
	  "#annotate panel Quiet trace=off\n"
	  "#annotate panel Lamp label=\"Front\"\n",
    Tmp = "/tmp/csp_trace.csp",
    ok = file:write_file(Tmp, Src),
    flush(),
    B0 = calls(),
    P = track_panel(spawn(fun() -> candid:run(fake_ws, "panel", Tmp) end)),
    timer:sleep(?SETTLE),
    C = calls() -- B0,
    P ! stop,
    timer:sleep(300),
    Labels = [X || X <- C, string:prefix(X, "ASYNC cast call [null,{ctx},110")
			       =/= nomatch],
    expect("the trace is labelled, and trace=off leaves a row out",
	   case Labels of
	       [L] -> string:find(L, "Front") =/= nomatch andalso
		      string:find(L, "Btn") =/= nomatch andalso
		      string:find(L, "Quiet") =:= nomatch;
	       _ -> false
	   end, Labels),

    Off = Src ++ "#annotate panel * trace=off\n",
    ok = file:write_file(Tmp, Off),
    {ok, AO} = candyspeak:parse(Tmp),
    expect("candyspeak accepts * as a target",
	   element(1, candyspeak:build(Tmp)) =:= ok, candyspeak:build(Tmp)),
    expect("a `*' key is a default every widget inherits",
	   lists:all(fun(#{trace := T}) -> T =:= false end,
		     maps:values(candid:looks(AO))), ok),
    flush(),
    B2 = calls(),
    P2 = track_panel(spawn(fun() -> candid:run(fake_ws, "panel", Tmp) end)),
    timer:sleep(?SETTLE),
    C2 = calls() -- B2,
    P2 ! stop,
    timer:sleep(300),
    expect("* trace=off: no trace canvas at all",
	   [X || X <- C2, string:find(X, "createElement canvas") =/= nomatch]
	   =:= [], length(C2)).

%% One plot, built from the annotation text under test.
clip_of(Opts) ->
    Src = "#analog c:10 in unsigned 0\n"
	  "#annotate panel c kind=plot axis=y id=g " ++ Opts ++ "\n",
    Tmp = "/tmp/csp_clip.csp",
    ok = file:write_file(Tmp, Src),
    {ok, A} = candyspeak:parse(Tmp),
    [G] = candid:plots(A),
    maps:get(clip, G).

%% Where a pixel 60 levels above the background ends up after 200 ticks.
decay(F, D) -> lists:foldl(fun(_, X) -> F(X) end, D, lists:seq(1, 200)).

%% A #field reads as an analog channel of the width its window has. WHO OWNS THE
%% VALUE decides whether the panel may drive it: a buffer with a transport is
%% filled by that transport, and the panel must not fight the wire.
field_check() ->
    Src = "#buffer Sock:4 in tcp 5555\n"
	  "#buffer Plain:4 in\n"
	  "#field  Sx:16 unsigned Sock[0..15]\n"
	  "#field  Wide Plain[0..11]\n"
	  "#field  Bit  Plain[9]\n",
    Tmp = "/tmp/csp_field.csp",
    ok = file:write_file(Tmp, Src),
    {ok, A} = candyspeak:parse(Tmp),
    W = candid:widgets(A),
    expect("a field on a socket is read-only, one on a plain buffer is not",
	   W =:= [{meter, "Sx", 16}, {slider, "Wide", 12}, {slider, "Bit", 1}],
	   W),

    %% The declared :width when there is one, else the window itself.
    expect("the width comes from the window when the field does not say",
	   [Wd || {_K, _N, Wd} <- W] =:= [16, 12, 1], W),

    %% A field fed from a socket, plotted. This is the whole point: the bytes
    %% arrive on tcp and the fields are the window onto them.
    Plot = "#buffer In:4 in tcp 5557\n"
	   "#field  Px:16 unsigned In[0..15]\n"
	   "#field  Py:16 In[16..31]\n"
	   "#annotate panel Px kind=plot axis=x id=scope\n"
	   "#annotate panel Py kind=plot axis=y id=scope color=cyan\n",
    Tmp2 = "/tmp/csp_field_plot.csp",
    ok = file:write_file(Tmp2, Plot),
    {ok, A2} = candyspeak:parse(Tmp2),
    expect("socket-fed fields become plot channels",
	   candid:widgets(A2) =:= [{plot, "Px", 16}, {plot, "Py", 16}],
	   candid:widgets(A2)),
    [G] = candid:plots(A2),
    X = maps:get(x, G),
    [Y] = maps:get(ys, G),
    %% ...and the SWING is the declared one. `Py' has no `unsigned', so it is
    %% signed -- 0..65535 would draw the top half of the picture and clip
    %% everything below zero into the bottom edge.
    expect("an unsigned field swings 0..full, a signed one both ways",
	   {maps:get(min, X), maps:get(max, X)} =:= {0, 65535} andalso
	   {maps:get(min, Y), maps:get(max, Y)} =:= {-32768, 32767},
	   {maps:get(min, X), maps:get(max, X),
	    maps:get(min, Y), maps:get(max, Y)}),
    expect("color= names the beam", maps:get(colour, Y) =:= "#3dd",
	   maps:get(colour, Y)).

%% The plot canvas's event id, taken from the handler the panel built: the body
%% carries both the id and the channel name, so the test does not have to count
%% create_event calls in render order.
plot_event() ->
    [B | _] = [X || X <- calls(), string:find(X, "'xin='") =/= nomatch],
    "Wse.notify(" ++ Rest = string:find(B, "Wse.notify("),
    {Id, _} = string:to_integer(Rest),
    Id.

annotate_check() ->
    {ok, A} = candyspeak:parse("demo/home.csp"),
    W = candid:widgets(A),
    Kind = fun(N) -> case [K || {K, N2, _} <- W, N2 =:= N] of
			 [K] -> K; _ -> none end end,
    %% BathMotion is the push in home.csp -- motion is a pulse. The buttons are
    %% switches on purpose: a held mouse button is a mouse button not clicking
    %% anything else, so an armed house could not be poked at.
    expect("#annotate kind=push overrides the derived toggle",
	   Kind("BathMotion") =:= push, Kind("BathMotion")),
    expect("#annotate kind=toggle is honoured too",
	   Kind("ArmButton") =:= toggle andalso
	   Kind("NightButton") =:= toggle,
	   {Kind("ArmButton"), Kind("NightButton")}),
    expect("an un-annotated digital in stays a toggle",
	   Kind("FrontDoor") =:= toggle, Kind("FrontDoor")),
    expect("#annotate kind=action and kind=dial",
	   Kind("Siren__Red") =:= action andalso Kind("IndoorTemp") =:= dial,
	   {Kind("Siren__Red"), Kind("IndoorTemp")}),

    %% A kind the declaration cannot be is refused, not obeyed: a panel that
    %% renders a dial for a digital pin cannot drive the pin it is wired to.
    Bad = "#digital B in pullup 2\n#annotate panel B kind=dial\n",
    Tmp = "/tmp/csp_ann_bad.csp",
    ok = file:write_file(Tmp, Bad),
    {ok, A2} = candyspeak:parse(Tmp),
    expect("an impossible kind is refused, derived kind stands",
	   [K || {K, "B", _} <- candid:widgets(A2)] =:= [toggle],
	   candid:widgets(A2)),

    %% and candyspeak itself catches a target that does not exist
    Typo = "#digital Led out 8\n#annotate panel Lde kind=push\n",
    Tmp2 = "/tmp/csp_ann_typo.csp",
    ok = file:write_file(Tmp2, Typo),
    expect("build rejects an annotation naming nothing",
	   case candyspeak:build(Tmp2) of
	       {error, {annotate_unknown_target, _, "Lde", _}} -> true;
	       _ -> false
	   end, candyspeak:build(Tmp2)).

%% What the translator models beyond plain signals: #local formulas, input
%% buffers, frozen #params, and stores that wrap at the declared width.
varp_model_check() ->
    Gen = fun(Name, Src, Opts) ->
		  Tmp = "/tmp/csp_varp_" ++ Name ++ ".csp",
		  ok = file:write_file(Tmp, Src),
		  {ok, Io} = candyspeak_varp:translate(Tmp, Opts),
		  {Tmp, lists:flatten(Io)}
	  end,
    Has = fun(T, S) -> string:find(T, S) =/= nomatch end,

    {_, T1} = Gen("local",
		  "#digital A in 2\n#digital L out 8\n#variable Prev:1 = 0\n"
		  "#local Edge:1 = A && !Prev\nPrev = A\nL = 1 ? Edge\n", []),
    expect("a #local is a macro, and a rule reading it is translated",
	   Has(T1, "define Edge() ") andalso Has(T1, "? Edge()") andalso
	   not Has(T1, "u_free"), T1),

    {_, T2} = Gen("buffer",
		  "#digital L out 8\n#buffer F:8 in can 0x10\n#param Pos = 1\n"
		  "#local B:1 = (F[Pos] & 0x40) != 0\nL = 1 ? F.rx && B\n", []),
    expect("an input buffer is free bytes and .rx; a byte index is a choice",
	   Has(T2, "F_b7:8") andalso Has(T2, "F_rx:1") andalso
	   Has(T2, "(Pos) == 7 ? F_b7") andalso not Has(T2, "u_free"), T2),

    {_, T3} = Gen("param", "#param P:8 unsigned = 3\n#digital L out 8\n"
		  "#constant K = 5\nL = 1 ? P == K\n", []),
    expect("a #param is frozen, a #constant is a define",
	   Has(T3, "next  next(P) == P;") andalso
	   not Has(T3, "define P ") andalso Has(T3, "define K 5;"), T3),
    {_, T4} = Gen("param", "#param P:8 unsigned = 3\n#digital L out 8\n"
		  "#constant K = 5\nL = 1 ? P == K\n", [{params, fixed}]),
    expect("{params, fixed} makes a #param its declared number",
	   Has(T4, "define P 3;") andalso not Has(T4, "next(P)"), T4),

    %% varp compares exactly, so an unwrapped `next(N) == N + 1' has no
    %% successor at 255 and every path through it is cut off.
    {Tmp5, T5} = Gen("wrap", "#variable N:8 unsigned = 255\n"
		     "#variable S:8 = 127\nN = N + 1\nS = S + 1\n", []),
    expect("a store wraps at the declared width",
	   Has(T5, "> 255 ? ((N) + (1)) - 256") andalso
	   Has(T5, "> 127 ? ((S) + (1)) - 256"), T5),
    case os:find_executable("varp") of
	false -> io:format("skip  varp run (no varp on PATH)~n");
	Varp ->
	    V5 = filename:rootname(Tmp5) ++ ".varp",
	    ok = file:write_file(V5, T5),
	    Out = os:cmd(Varp ++ " bmc --runs --k-min 2 --k-max 2"
			 " --trace false " ++ V5 ++ " 2>&1 | tail -1"),
	    expect("a counter at 255 still has a next step",
		   Has(Out, "% 1"), Out)
    end.

%% `#annotate varp <kind> "candyspeak expression"': parsed by candyspeak,
%% translated as a guard, and an error when the model cannot say it.
varp_prop_check() ->
    Light = "#digital Red out 1\n#digital Yellow out 2\n#digital Green out 3\n"
	"#digital Go in 4\n#variable Phase:2 unsigned = 0\n"
	"Phase = (Phase + 1) % 3 ? Go\n"
	"Red = Phase == 0\nYellow = Phase == 1\nGreen = Phase == 2\n",
    Tr = fun(Name, Anns) ->
		 Tmp = "/tmp/csp_varp_" ++ Name ++ ".csp",
		 ok = file:write_file(Tmp, Light ++ Anns),
		 {Tmp, candyspeak_varp:translate(Tmp)}
	 end,
    Has = fun(T, S) -> string:find(T, S) =/= nomatch end,

    {Tmp, {ok, Io}} =
	Tr("prop", "#annotate varp invariant \"(Red+Yellow+Green) <= 1\"\n"
	   "#annotate varp invariant \"Phase != 3\"\n"
	   "#annotate varp assume \"Go\"\n"
	   "#annotate varp reach \"Green && Phase == 0\"\n"),
    T = lists:flatten(Io),
    expect("invariants are conjoined with FAILSAFE, each line noted",
	   Has(T, "invariant St != FAILSAFE\n        and (") andalso
	   Has(T, "and ((Phase) != (3));") andalso
	   Has(T, "// line 11: Phase != 3"), T),
    expect("assume and reach are their own items",
	   Has(T, "assume    (Go) != 0;") andalso
	   Has(T, "reach     ((Green) != 0) and ((Phase) == (0));"), T),
    case os:find_executable("varp") of
	false -> io:format("skip  varp run (no varp on PATH)~n");
	Varp ->
	    V = filename:rootname(Tmp) ++ ".varp",
	    ok = file:write_file(V, T),
	    Ind = os:cmd(Varp ++ " bmc --induction " ++ V ++ " 2>&1 | tail -1"),
	    expect("the invariant is proved", Has(Ind, "% TRUE"), Ind),
	    Re = os:cmd(Varp ++ " bmc --k-max 6 --trace false --property "
			"csp_varp_prop_reach " ++ V ++ " 2>&1 | tail -2"),
	    expect("reach finds green with the phase wrapped",
		   Has(Re, "counterexample at k=3"), Re)
    end,

    Err = fun(Name, Ann) -> element(2, Tr(Name, "#annotate varp " ++ Ann ++ "\n")) end,
    E1 = Err("e1", "invariant \"Red + Blue <= 1\""),
    expect("a name the model lacks is an error, with the line",
	   E1 =:= {error, {varp_annotate, "10", "invariant",
			   {not_modelled, "Red + Blue <= 1", ["Blue"]}}}, E1),
    E2 = Err("e2", "never \"Red\""),
    expect("an unknown kind is an error",
	   E2 =:= {error, {varp_annotate, "10", "never", unknown_kind}}, E2),
    E3 = Err("e3", "invariant \"Red Yellow\""),
    expect("a syntax error in the string is reported at the annotation",
	   element(1, element(2, E3)) =:= varp_annotate andalso
	   element(2, element(2, E3)) =:= "10", E3),
    E4 = Err("e4", "reach \"Red\"\n#annotate varp reach \"Green\""),
    expect("one reach at most",
	   E4 =:= {error, {varp_annotate, "11", "reach", more_than_one}}, E4).

%% The code view: rules numbered as csp numbers them, conditions evaluated
%% from the dump, and csp's own word on which rules fired.
code_view_check() ->
    %% A #timer with a #param period compiles to a rule at its declaration,
    %% so cpx_rotate's eleven written rules are thirteen (csp -P agrees).
    {ok, Rot} = candyspeak:parse(tree("examples/cpx_rotate.csp")),
    Nos = [N || #{no := N} <- csp_code:rules(Rot)],
    expect("rules numbered as csp numbers them", Nos =:= lists:seq(1, 13), Nos),
    {ok, Add} = candyspeak:parse(tree("examples/adder3.csp")),
    Tabs = csp_code:tabs(Add),
    expect("a tab per object, after main, each with its module's rules",
	   [maps:get(name, T) || T <- Tabs] =:= ["main", "a0", "a1", "a2"] andalso
	   length(maps:get(rules, lists:nth(2, Tabs))) =:= 2 andalso
	   length([R || R = #{} <- maps:get(rules, hd(Tabs))]) =:= 3, Tabs),
    %% A module's analog is a widget per object, named as csp dumps it.
    {ok, Cpx} = candyspeak:parse(tree("examples/cpx_m.csp")),
    Pix = [N || {pixel, N, _} <- candid:widgets(Cpx)],
    expect("a pixel declared in a module is one per object",
	   Pix =:= ["p" ++ integer_to_list(I) ++ ".P" || I <- lists:seq(0, 9)],
	   Pix),

    Src = "#digital Go in 4\n#variable Phase:2 unsigned = 0\n"
	"#variable Red:1 = 0\n#variable S:8 = 0\n#timer T 100\n"
	"#local Odd:1 = Phase == 1\n"
	"Phase = (Phase + 1) % 3 ? Go\n"
	"Red = Phase == 0\n"
	"Red = 0 ? Odd\n",
    F = "/tmp/csp_code_check.csp",
    ok = file:write_file(F, Src),
    {ok, A} = candyspeak:parse(F),
    E = candyspeak_eval:env(A),
    Ev = fun(Txt, Vals) ->
		 {ok, [{define, _, _, X}]} = candyspeak_parse:parse(
					       element(2, candyspeak_scan:string(
							    "#define P_ " ++ Txt ++ "\n"))),
		 candyspeak_eval:eval(X, Vals, E)
	 end,
    expect("a local is its formula over the dump",
	   Ev("Odd", #{"Phase" => 1}) =:= 1 andalso
	   Ev("Odd", #{"Phase" => 2}) =:= 0, nomatch),
    expect("a signed variable reads sign-extended",
	   Ev("S < 0", #{"S" => 16#FF}) =:= 1, Ev("S < 0", #{"S" => 16#FF})),
    expect("false && unknown is false, true && unknown unknown",
	   Ev("!Go && elapsed(T) > 5", #{"Go" => 1}) =:= 0 andalso
	   Ev("Go && elapsed(T) > 5", #{"Go" => 1}) =:= unknown, nomatch),

    %% --fired, through csp_link. Paused with Go set, ONE step sees it --
    %% csp_link:step/2 commits what was set first -- and fires Phase's rule
    %% (line 7) and `Red = Phase == 0' (8); `Red = 0 ? Odd' (9) does not,
    %% Phase was 0.
    flush(),
    {ok, L} = csp_link:open(csp_exe(), [F]), track(L),
    timer:sleep(200),
    csp_link:pause(L),
    timer:sleep(100),
    csp_link:set(L, "Go", 1),
    timer:sleep(100),
    flush(),
    csp_link:step(L),
    timer:sleep(300),
    Fired = last_fired(undefined),
    csp_link:close(L),
    timer:sleep(250),
    expect("csp says which rules fired, by file and line",
	   Fired =:= [{"", F, 7}, {"", F, 8}], Fired),

    %% A module's rule fires once per instance, and says which.
    flush(),
    {ok, L2} = csp_link:open(csp_exe(), [tree("examples/adder3.csp")]),
    track(L2),
    timer:sleep(300),
    csp_link:tick(L2),
    timer:sleep(300),
    Fired2 = last_fired([]),
    csp_link:close(L2),
    timer:sleep(250),
    expect("a module's rule is reported per object",
	   lists:member({"a1", tree("examples/adder3.csp"), 8}, Fired2) andalso
	   lists:member({"", tree("examples/adder3.csp"), 23}, Fired2), Fired2),

    %% Marks: a contact in an object's tab is named as it is outside it.
    Mod = "#module M\n  #variable X:1 unsigned in\n"
	"  #variable Y:1 unsigned out\n  Y = 1 ? X && Go\n#end\n"
	"#digital Go in 4\n#variable N:4 = 0\n#M m0 X=Go\n"
	"N = 0 ? N > 2 || Go\n",
    Fm = "/tmp/csp_code_marks.csp",
    ok = file:write_file(Fm, Mod),
    {ok, Am} = candyspeak:parse(Fm),
    Vm = #{tabs => csp_code:tabs(Am)},
    Ev2 = fun(Txt) ->
		  {ok, [{define, _, _, X}]} = candyspeak_parse:parse(
						element(2, candyspeak_scan:string(
							     "#define P_ " ++ Txt ++ "\n"))),
		  X
	  end,
    Mx = csp_code:contact_of(Vm, 1, "k1_0"),
    Mg = csp_code:contact_of(Vm, 1, "k1_1"),
    Mn = csp_code:contact_of(Vm, 0, "k1_0"),
    Goal = csp_code:goal_text(#{{1, "k1_0"} => {true, Mx},
				{1, "k1_1"} => {false, Mg},
				{0, "k1_0"} => {false, Mn}}),
    expect("marks add up to one condition, objects' names made whole",
	   Goal =:= "!(N > 2) && m0.X && !Go", Goal),
    NotNot = csp_code:goal_text(#{{0, "k1_0"} => {false, Ev2("!Go")}}),
    expect("a contact `!X' marked false is X, not !!X", NotNot =:= "Go", NotNot),
    model_check().

%% prove/5: no trace, and then whether there never is one. Yellow && Green
%% is ruled out by the rules alone (0-induction); B is 1 only one step after
%% A, which is 0 after the first step (1-induction); N and M count in step,
%% so N == 3 && M == 5 never happens, but only a run of 16 shows it.
prove_check(Sh) ->
    F = "/tmp/csp_varp_prove.csp",
    ok = file:write_file(F, "#digital B1 in 2\n#digital B2 in 3\n"
			 "#digital B3 in 4\n#variable Yellow:1 = 0\n"
			 "#variable Green:1 = 0\n#variable A:1 = 0\n"
			 "#variable B:1 = 0\n#variable N:4 = 0\n"
			 "#variable M:4 = 0\n"
			 "Yellow = B1 + B2 + B3 == 1\n"
			 "Green = B1 && B2 && B3\n"
			 "A = 0\nB = A\nN = N + 1\nM = M + 1\n"),
    Ask = fun(G) ->
		  {ok, M} = candyspeak_varp:model(F, [{reach, G}]),
		  candyspeak_varp:prove(M, "--property " ++ maps:get(name, M) ++
					    "_reach", 10, 30, Sh)
	  end,
    R0 = Ask("Yellow && Green"),
    expect("prove: Yellow && Green never, by the rules alone",
	   R0 =:= {proved, 0}, R0),
    R1 = Ask("B"),
    expect("prove: B never, with one step of history", R1 =:= {proved, 1}, R1),
    Ru = Ask("N == 3 && M == 5"),
    expect("prove: not within 10, not proved either", element(1, Ru) =:= none,
	   Ru),
    Rf = Ask("Yellow && B1"),
    expect("prove: a goal that is reached has its trace",
	   element(1, Rf) =:= found andalso element(2, Rf) =:= 1, Rf).

%% The model view's side of candyspeak_varp: the question replaces the
%% source's reach, varp's printed trace reads back as data, and -- when varp
%% is here -- a goal on traffic.csp is reached, and not within one step.
model_check() ->
    Out = "bmc: counterexample at k=2\n"
	"  step  Green  St  u_free0_L26  input\n"
	"     0      0   0            -\n"
	"     1      0   3            1\n"
	"     2      1   3            1\n% 1\n",
    T = candyspeak_varp:trace(Out),
    expect("varp's trace reads back as rows, `-' as any value",
	   T =:= {found, 2, [[{"Green", 0}, {"St", 0}, {"u_free0_L26", '-'},
			      {"input", '-'}],
			     [{"Green", 0}, {"St", 3}, {"u_free0_L26", 1},
			      {"input", '-'}],
			     [{"Green", 1}, {"St", 3}, {"u_free0_L26", 1},
			      {"input", '-'}]]}, T),
    expect("% 0 is no trace", candyspeak_varp:trace("% 0\n") =:= {none, "% 0"},
	   candyspeak_varp:trace("% 0\n")),
    Pr = candyspeak_varp:trace("bmc: proved by 2-induction\n% TRUE\n"),
    expect("a proof reads back with its k", Pr =:= {proved, 2}, Pr),
    F = tree("examples/traffic.csp"),
    {ok, M} = candyspeak_varp:model(F, [{reach, "LongRed && Please"}]),
    Text = lists:flatten(maps:get(text, M)),
    expect("the asked reach is in the model, with what it leaves free",
	   string:find(Text, "reach     ((LongRed) != 0) and ((Please) != 0);   // goal:") =/= nomatch andalso
	   maps:get(inputs, M) =:= ["Please"] andalso
	   lists:keyfind("red", 1, maps:get(states, M)) =:= {"red", 4},
	   {maps:get(inputs, M), maps:get(states, M)}),
    Sh = filename:join(os:getenv("HOME"), "erlang/varp/priv/varp.sh"),
    case filelib:is_regular(Sh) of
	false -> io:format("skip  varp runs (no ~s)~n", [Sh]);
	true ->
	    Ask = fun(K) ->
			  candyspeak_varp:bmc(
			    maps:get(text, M), "--timeout 30 bmc --property "
			    "traffic_reach --k-max " ++ integer_to_list(K), Sh)
		  end,
	    R10 = Ask(10),
	    expect("traffic: LongRed && Please is reached", element(1, R10) =:=
		       found, R10),
	    R1 = Ask(1),
	    expect("...but not within one step", element(1, R1) =:= none, R1),
	    prove_check(Sh),
	    shift_check(Sh),
	    timer_check(Sh),
	    shift_ops_check(Sh),
	    object_check(Sh)
    end,

    %% Only the part of a guard the model cannot read is free, and one choice
    %% serves every assignment of the rule.
    ok = file:write_file("/tmp/csp_varp_abs.csp",
			 "#variable M:1 = 0\n#variable E:1 = 0\n"
			 "#variable On:1 = 0\n#timer T 100\n"
			 "E = 1, On = 0 ? M && progress(T) > 3\n"),
    {ok, Ma} = candyspeak_varp:model("/tmp/csp_varp_abs.csp", []),
    Ta = lists:flatten(maps:get(text, Ma)),
    expect("a guard keeps what translates; one free choice per rule",
	   maps:get(abstract, Ma) =:= [{"u_free0_L5", 5}] andalso
	   string:find(Ta, "((M) != 0) and (u_free0_L5 == 1)") =/= nomatch,
	   {maps:get(abstract, Ma), Ta}),

    %% #when is part of the guard of every rule in it, and its #end closes it
    %% and not the #in around it.
    ok = file:write_file("/tmp/csp_varp_when.csp",
			 "#variable M:1 = 0\n#variable N:4 = 0\n#states A\n"
			 "#in INIT\n  State = A\n#end\n"
			 "#in A\n#when M\n  N = 5\n#end\n  N = 1 ? N == 0\n#end\n"),
    {ok, Mw} = candyspeak_varp:model("/tmp/csp_varp_when.csp", []),
    Tw = lists:flatten(maps:get(text, Mw)),
    expect("#when gates its rules; its #end leaves the #in open",
	   string:find(Tw, "9: N = 5 ? (M) != 0") =/= nomatch andalso
	   string:find(Tw, "((St == A) and ((M) != 0))") =/= nomatch andalso
	   string:find(Tw, "((St == A) and ((N) == (0)))") =/= nomatch, Tw),

    %% A signal marked from its label or cell: on for one bit, its value now
    %% for more.
    {ok, Ag} = candyspeak:parse(tree("examples/traffic.csp")),
    Vg = #{tabs => csp_code:tabs(Ag), last => #{"LongRed" => 7}},
    S1 = csp_code:goal_text(#{{sig, "Red"} => {true, csp_code:sig_expr(Vg, "Red")},
			      {sig, "LongRed"} => {false, csp_code:sig_expr(Vg, "LongRed")}}),
    expect("signals as marks: `Red', `!(LongRed == 7)'",
	   S1 =:= "!(LongRed == 7) && Red", S1).

%% A timer is two state variables and the time before each step: declared
%% `= 1' it is started by the setup, before INIT, and a 500 ms one restarted
%% on its own timeout counts once per step, however long the step.
timer_check(Sh) ->
    F = "/tmp/csp_varp_timer.csp",
    ok = file:write_file(F, "#timer T 500 = 1\n#variable X:8 = 0\n"
			 "#variable E:1 = 0\n"
			 "X = X + 1 ? timeout(T)\nT = 1 ? timeout(T)\n"
			 "E = 1 ? elapsed(T) >= 200 && elapsed(T) < 300\n"),
    Ask = fun(Goal, K) ->
		  {ok, M} = candyspeak_varp:model(F, [{reach, Goal}]),
		  candyspeak_varp:bmc(maps:get(text, M),
				      "--timeout 30 bmc --property "
				      "csp_varp_timer_reach --k-max " ++
					  integer_to_list(K), Sh)
	  end,
    R1 = Ask("X == 2", 1),
    R2 = Ask("X == 2", 4),
    expect("timer: two timeouts take two steps of 500 ms or more",
	   element(1, R1) =:= none andalso element(1, R2) =:= found andalso
	   element(2, R2) =:= 2 andalso
	   [D || Row <- tl(element(3, R2)), {"u_dt", D} <- Row,
		 not (is_integer(D) andalso D >= 500)] =:= [],
	   {R1, R2}),
    %% Walking the trace: the cycle 1 -> 2 is the second timeout, read from
    %% the model's timer and the time that comes in.
    {ok, Mt} = candyspeak_varp:model(F, [{reach, "X == 2"}]),
    Vt = #{trace => {element(3, R2), Mt}, look => 1, states => []},
    Lv = csp_code:look_values(Vt),
    Lt = csp_code:look_text(Vt),
    expect("the code view walks a trace: timeout(T) holds, X changes",
	   maps:get({timeout, "T"}, Lv) =:= 1 andalso maps:get("X", Lv) =:= 1
	   andalso string:find(Lt, "step 1 -> 2:") =/= nomatch andalso
	   string:find(Lt, "X=2") =/= nomatch, {Lv, Lt}),
    RE = Ask("E", 4),
    expect("timer: elapsed() is read, not guessed",
	   element(1, RE) =:= found andalso element(2, RE) =:= 1, RE).

%% A shift by a constant of a value that cannot be negative is varp's own
%% shift; by a variable, it is not translated.
shift_ops_check(Sh) ->
    F = "/tmp/csp_varp_shl.csp",
    ok = file:write_file(F, "#analog In:4 unsigned 0\n"
			 "#variable Y:8 unsigned = 0\n#variable Z:8 unsigned = 0\n"
			 "#variable B:1 unsigned = 0\n#variable N:8 unsigned = 0\n"
			 "Y = (In << 3) + 1\nZ = Y >> 2\nB = (Y >> 3) & 1\n"
			 "N = Y << In\n"),
    {ok, M} = candyspeak_varp:model(F, [{reach, "Z == 30 && B"}]),
    T = lists:flatten(maps:get(text, M)),
    R = candyspeak_varp:bmc(maps:get(text, M), "--timeout 30 bmc --property "
			    "csp_varp_shl_reach --k-max 4", Sh),
    expect("shifts by a constant are modelled, by a variable not",
	   string:find(T, "((In) << 3)") =/= nomatch andalso
	   maps:get(free, M) =:= ["N"] andalso
	   element(1, R) =:= found andalso element(2, R) =:= 2, {R, T}).

%% Objects are flattened: every member once per instance as `a.N', its own
%% State, a static binding written in the instance's INIT, a timer's period
%% from its line. Two counters on one module are two counters.
object_check(Sh) ->
    F = "/tmp/csp_varp_obj.csp",
    ok = file:write_file(F, "#module Cnt\n  #states Up\n"
			 "  #variable N:4 unsigned = 0\n  #variable Go:1 in = 0\n"
			 "  #timer T 100 = 1\n"
			 "  #in INIT\n    State = Up\n  #end\n"
			 "  #in Up\n    N = N + 1, T = 1 ? Go && timeout(T)\n  #end\n"
			 "#end\n"
			 "#digital In:1 in\n"
			 "#Cnt a Go = 1\n#Cnt b T.period = 300\n"
			 "b.Go = In\n"),
    {ok, M} = candyspeak_varp:model(F, [{reach, "a.N == 2 && b.N == 1"}]),
    T = lists:flatten(maps:get(text, M)),
    expect("objects: a member per instance, a State each, names kept",
	   string:find(T, "state a_State:") =/= nomatch andalso
	   string:find(T, "next(a_Go) == 1") =/= nomatch andalso
	   string:find(T, "u_el_b_T + u_dt >= 300") =/= nomatch andalso
	   maps:get("a_N", maps:get(names, M)) =:= "a.N", T),
    Ask = fun(K) ->
		  candyspeak_varp:bmc(maps:get(text, M),
				      "--timeout 30 bmc --property "
				      "csp_varp_obj_reach --k-max " ++
					  integer_to_list(K), Sh)
	  end,
    R2 = Ask(2),
    R6 = Ask(6),
    expect("objects: a and b count apart",
	   element(1, R2) =:= none andalso element(1, R6) =:= found, {R2, R6}),
    D = "demo/dl1200_deb_lib.csp",
    {ok, Md} = candyspeak_varp:model(D, [{reach, "EnDb.Out"}, {params, fixed}]),
    AskD = fun(K) ->
		   candyspeak_varp:bmc(maps:get(text, Md),
				       "--timeout 30 bmc --property "
				       "dl1200_deb_lib_reach --k-max " ++
					   integer_to_list(K), Sh)
	   end,
    R7 = AskD(7),
    R8 = AskD(8),
    expect("dl1200_deb_lib: lib/debounce settles in five ticks",
	   element(1, R7) =:= none andalso element(1, R8) =:= found andalso
	   element(2, R8) =:= 8, {R7, element(1, R8)}).

%% dl1200_shift.csp: five equal samples, two bits each, before Enable is
%% believed -- so EnDeb cannot be on within five steps, and is at six.
shift_check(Sh) ->
    F = "demo/dl1200_shift.csp",
    case filelib:is_regular(F) of
	false -> io:format("skip  dl1200_shift (no ~s)~n", [F]);
	true ->
	    {ok, M} = candyspeak_varp:model(F, [{reach, "EnDeb"},
						 {params, fixed}]),
	    Ask = fun(K) ->
			  candyspeak_varp:bmc(
			    maps:get(text, M), "--timeout 30 bmc --property "
			    "dl1200_shift_reach --k-max " ++ integer_to_list(K),
			    Sh)
		  end,
	    expect("dl1200: the replay sends CanFrame on 0x30 (CANID)",
		   maps:get(frames, M) =:= [{"CanFrame", 48, 8}],
		   maps:get(frames, M)),
	    expect("dl1200: no rule sees a frame in INIT",
		   string:find(lists:flatten(maps:get(text, M)),
			       "(St == INIT ? 0 : CanFrame_rx)") =/= nomatch,
		   nomatch),
	    R5 = Ask(5),
	    R10 = Ask(10),
	    expect("shift register: EnDeb needs five samples",
		   element(1, R5) =:= none andalso
		   element(1, R10) =:= found andalso element(2, R10) =:= 6,
		   {R5, element(2, R10)})
    end.

last_fired(Acc) ->
    receive
	{csp_fired, _, Rs} -> last_fired(Rs);
	{csp_state, _, _}  -> last_fired(Acc)
    after 0 -> Acc
    end.

varp_gen_check() ->
    F = "demo/home.csp",
    case filelib:is_regular(F) of
	false -> io:format("skip  varp generator (no home.csp)~n");
	true ->
	    {ok, Io} = candyspeak_varp:translate(F),
	    Text = lists:flatten(Io),
	    expect("varp model names its states",
		   string:find(Text, "define Home 3;") =/= nomatch andalso
		   string:find(Text, "St == Home or St == Night") =/= nomatch,
		   nomatch),
	    %% a state whose name a signal already has keeps the number
	    Clash = "#digital Led out 8\n#variable Home = 0\n"
		    "#states Home Away\n#in INIT\n    State = Home\n#end\n",
	    Tmp = "/tmp/csp_varp_clash.csp",
	    ok = file:write_file(Tmp, Clash),
	    {ok, Io2} = candyspeak_varp:translate(Tmp),
	    T2 = lists:flatten(Io2),
	    expect("a state whose name is taken keeps its number",
		   string:find(T2, "define Home") =:= nomatch andalso
		   string:find(T2, "define Away 4;") =/= nomatch,
		   nomatch),

	    %% The runtime SKIPS a reserved name in #states -- FAILSAFE resolves
	    %% to the built-in 2 and takes no slot, so A is 3 (measured). Getting
	    %% this wrong shifted every state by one and defined FAILSAFE twice:
	    %% a model of a different program, with nothing to show it.
	    Res = "#states FAILSAFE A B\n#digital L out 8\n",
	    Tmp2 = "/tmp/csp_varp_reserved.csp",
	    ok = file:write_file(Tmp2, Res),
	    {ok, Io3} = candyspeak_varp:translate(Tmp2),
	    T3 = lists:flatten(Io3),
	    expect("a reserved name in #states takes no slot",
		   string:find(T3, "define A 3;") =/= nomatch andalso
		   string:find(T3, "define B 4;") =/= nomatch andalso
		   string:find(T3, "define FAILSAFE 3;") =:= nomatch,
		   nomatch),

	    %% #import: a program split in two is the SAME program. home.csp cut
	    %% at its first #states or #in -- declarations before, logic after
	    %% -- and the logic half importing the rest must translate to exactly
	    %% the text the whole file does. Same basename in both directories,
	    %% since the header names the file.
	    {ok, HomeBin} = file:read_file(F),
	    HomeLines = string:split(binary_to_list(HomeBin), "\n", all),
	    {Decls, Logic} =
		lists:splitwith(fun(L) -> not (lists:prefix("#states", L) orelse
					       lists:prefix("#in", L)) end,
				HomeLines),
	    Join = fun(Ls) -> lists:flatten(lists:join("\n", Ls)) end,
	    ok = filelib:ensure_dir("/tmp/csp_varp_split/x"),
	    ok = filelib:ensure_dir("/tmp/csp_varp_whole/x"),
	    ok = file:write_file("/tmp/csp_varp_split/decls.csp", Join(Decls)),
	    ok = file:write_file("/tmp/csp_varp_split/home.csp",
				 Join(["#import \"decls.csp\"" | Logic])),
	    ok = file:write_file("/tmp/csp_varp_whole/home.csp", HomeBin),
	    {ok, IoS} = candyspeak_varp:translate("/tmp/csp_varp_split/home.csp"),
	    {ok, IoW} = candyspeak_varp:translate("/tmp/csp_varp_whole/home.csp"),
	    %% The rules are all in the logic half, so their line numbers move
	    %% by the declarations cut out -- that and nothing else.
	    NoLines = fun(Io) ->
			      NL1 = re:replace(lists:flatten(Io), "_L[0-9]+", "_L",
					       [global, {return, list}]),
			      NL2 = re:replace(NL1, "//   [0-9]+:", "//   N:",
					       [global, {return, list}]),
			      re:replace(NL2, "//   line [0-9]+", "//   line N",
					 [global, {return, list}])
		      end,
	    expect("an #import-split program translates to the same model",
		   Decls =/= [] andalso Logic =/= [] andalso
		   NoLines(IoS) =:= NoLines(IoW),
		   {length(Decls), length(Logic)}),

	    %% A rule that lives in an IMPORTED file is shown as file:line, and
	    %% its free input says the file too: "28" alone would point at a
	    %% line of the file being translated.
	    ok = file:write_file("/tmp/csp_varp_split/rules.csp",
				 "#digital A in 2\n#digital B out 8\n"
				 "B = 1 ? A == 1 && progress(T) > 3\n"),
	    ok = file:write_file("/tmp/csp_varp_split/top.csp",
				 "#timer T 100\n#import \"rules.csp\"\n"),
	    {ok, IoR} = candyspeak_varp:translate("/tmp/csp_varp_split/top.csp"),
	    TR = lists:flatten(IoR),
	    expect("a rule from an imported file is located as file:line",
		   string:find(TR, "rules.csp:3: B = 1") =/= nomatch andalso
		   string:find(TR, "u_free0_rules_L3") =/= nomatch,
		   TR),

	    %% ...and a missing import is an error, not a smaller model
	    ok = file:write_file("/tmp/csp_varp_split/broken.csp",
				 "#import \"nowhere.csp\"\n#digital L out 8\n"),
	    expect("an #import that finds nothing fails the translation",
		   element(1, candyspeak_varp:translate(
				"/tmp/csp_varp_split/broken.csp")) =:= error,
		   nomatch),

	    %% ...and a duplicate keeps the first, as the runtime does
	    Dup = "#states a b c d\n#states d e\n#digital L out 8\n",
	    Tmp3 = "/tmp/csp_varp_dup.csp",
	    ok = file:write_file(Tmp3, Dup),
	    {ok, Io4} = candyspeak_varp:translate(Tmp3),
	    T4 = lists:flatten(Io4),
	    expect("a duplicate state keeps the first number",
		   string:find(T4, "define d 6;") =/= nomatch andalso
		   string:find(T4, "define e 7;") =/= nomatch, nomatch)
    end.

home_checks() ->
    F = "demo/home.csp",
    case filelib:is_regular(F) of
	false -> io:format("skip  home (not found)~n");
	true ->
	    %% cold, window shut: the heater runs
	    A = settle(F, [{"IndoorTemp", 150}]),
	    expect("home: heater runs when cold",
		   maps:get("Heater__Orange", A, 0) =:= 1, A),
	    %% cold, window open: it must not
	    B = settle(F, [{"IndoorTemp", 150}, {"LivingWindow", 1}]),
	    expect("home: no heating into an open window",
		   maps:get("Heater__Orange", B, 1) =:= 0, B),
	    %% a door, alarm disarmed: silence
	    C = settle(F, [{"FrontDoor", 1}]),
	    expect("home: siren silent while disarmed",
		   maps:get("Siren__Red", C, 1) =:= 0, C),
	    %% ArmButton is a SWITCH, so it is held on -- `!ArmButton && Armed'
	    %% disarms on release, which is what a switch should do. Pressing and
	    %% releasing it (as this test first did) disarms before the door is
	    %% ever opened.
	    %%
	    %% And a switch rather than a push button for a practical reason:
	    %% holding a mouse button down means not clicking anything else, so
	    %% an armed house could not be poked at.
	    D = settle(F, [{"ArmButton", 1}], [{"FrontDoor", 1}]),
	    expect("home: siren sounds when armed and the door opens",
		   maps:get("Siren__Red", D, 0) =:= 1, D),

	    %% ...and turning the switch off disarms, siren included
	    E = settle(F, [{"ArmButton", 1}, {"FrontDoor", 1}],
		       [{"ArmButton", 0}]),
	    expect("home: the switch off disarms and silences",
		   maps:get("Armed", E, 1) =:= 0 andalso
		   maps:get("Siren__Red", E, 1) =:= 0, E),

	    %% The net must not fire in normal use, and must fire when prevention
	    %% is missing. Compared by STATE NUMBER against each other rather
	    %% than against a literal: the numbering is not the declaration
	    %% order (Home came out 3 and FAILSAFE 2), so a magic number here
	    %% would be a guess that happens to pass.
	    net_check(maps:get("State", B, -1))
    end.

%% Same file with the window guard deleted: the violation now persists, and the
%% net has to catch it and land softly.
net_check(NormalState) ->
    {ok, Src} = file:read_file("demo/home.csp"),
    Lines = string:split(binary_to_list(Src), "\n", all),
    Broken = [L || L <- Lines,
		   string:find(L, "Heater__Orange = 0 ? LivingWindow") =:= nomatch],
    Tmp = "/tmp/home_no_guard.csp",
    ok = file:write_file(Tmp, string:join(Broken, "\n")),
    V = settle(Tmp, [{"IndoorTemp", 150}], [{"LivingWindow", 1}]),
    Failsafe = maps:get("State", V, -1),
    expect("home: the net does not fire when prevention works",
	   NormalState =/= -1, NormalState),
    expect("home: the net catches a real violation",
	   Failsafe =/= NormalState, {normal, NormalState, broken, Failsafe}),
    %% and the landing is what makes FAILSAFE safe rather than merely stopped
    expect("home: FAILSAFE lands softly (lights on, heat off)",
	   maps:get("HallLight", V, 0) =:= 1 andalso
	   maps:get("OutdoorLamp", V, 0) =:= 1 andalso
	   maps:get("Heater__Orange", V, 1) =:= 0, V).

settle(F, Sets) -> settle(F, Sets, []).

%% Drive csp to a settled state with the given inputs, in two rounds so a
%% button can be pressed and released.
settle(F, Sets1, Sets2) ->
    %% Dumps from the PREVIOUS test's csp may still be in the mailbox, and they
    %% would be merged in as though they came from this program. That is not
    %% hypothetical: it made the first run of this check read cpx_rotate's
    %% pixels and report that home.csp had no heater.
    flush(),
    {ok, L} = csp_link:open(csp_exe(), [F]), track(L),
    Last = steps(L, 3, #{}),                       % reach Home first
    Last1 = apply_sets(L, Sets1, Last),
    Last2 = apply_sets(L, Sets2, Last1),
    csp_link:close(L),
    timer:sleep(250),
    Last2.

apply_sets(_L, [], Acc) -> Acc;
apply_sets(L, Sets, Acc) ->
    [csp_link:set(L, N, V) || {N, V} <- Sets],
    steps(L, 4, Acc).

steps(_L, 0, Acc) -> Acc;
steps(L, N, Acc) ->
    csp_link:tick(L),
    timer:sleep(60),
    Acc1 = receive {csp_state, _, V} -> maps:merge(Acc, maps:from_list(V))
	   after 0 -> Acc
	   end,
    steps(L, N - 1, Acc1).

array_check() ->
    F = tree("examples/cpx_rotate.csp"),
    case filelib:is_regular(F) of
	false -> io:format("skip  array (no cpx_rotate.csp)~n");
	true ->
	    {ok, A} = candyspeak:parse(F),
	    Ws = candid:widgets(A),
	    Px = [N || {pixel, N, _} <- Ws],
	    expect("an analog array becomes one widget per element",
		   Px =:= ["P[" ++ integer_to_list(I) ++ "]"
			   || I <- lists:seq(0, 9)], Px),
	    %% and the values reach those names
	    flush(),
	    {ok, L} = csp_link:open(csp_exe(), [F]), track(L),
	    {Vals, Lit} = lit_px(L, Px, 25, #{}, []),
	    csp_link:close(L),
	    timer:sleep(300),
	    expect("array elements get values from the dump",
		   length([1 || N <- Px, maps:is_key(N, Vals)]) =:= 10,
		   maps:keys(Vals)),
	    %% One pixel is lit at a time and it travels. The dump is a --delta,
	    %% so an element that changes alone has to say which one it is: when
	    %% it came out unnamed the lit pixel stayed put and others stuck on.
	    expect("one pixel lit at a time",
		   lists:all(fun(Ns) -> length(Ns) =< 1 end, Lit), Lit),
	    expect("the lit pixel travels",
		   length(lists:usort(lists:append(Lit))) >= 5, Lit)
    end.

%% After each tick: the merged values, and which pixels are non-zero.
lit_px(_L, _Px, 0, Acc, Lit) -> {Acc, lists:reverse(Lit)};
lit_px(L, Px, N, Acc, Lit) ->
    csp_link:tick(L),
    timer:sleep(60),
    Acc1 = merge_all(Acc),
    On = [P || P <- Px, maps:get(P, Acc1, 0) =/= 0],
    lit_px(L, Px, N - 1, Acc1, [On | Lit]).

%% Every dump that has arrived, in order: a tick can run more than one cycle.
merge_all(Acc) ->
    receive {csp_state, _, V} -> merge_all(maps:merge(Acc, maps:from_list(V)))
    after 0 -> Acc
    end.

flush() ->
    receive
	{csp_state, _, _} -> flush();
	{csp_fired, _, _} -> flush();
	{csp_exit, _}     -> flush()
    after 0 -> ok
    end.

%% A node's console on tcp: a csp behind a relay stands in for one. The link
%% reads its program with /dump rom (nothing stored, so no patch) and its
%% values with /dump state, named as the panel names them.
node_checks() ->
    expect("the target field reads",
	   [element(1, T) || S <- ["", "can0", "/dev/ttyACM0@9600 rom",
				   "h:2323 image=A", "local image=A", "h:x"],
			     T <- [csp_link:target(S)]] =:=
	       [ok, ok, ok, ok, error, error], nomatch),
    {ok, LS} = gen_tcp:listen(0, [list, {packet, line}, {active, false},
				  {reuseaddr, true}]),
    {ok, Port} = inet:port(LS),
    spawn(fun() -> relay(LS) end),
    flush(),
    {ok, T} = csp_link:target("localhost:" ++ integer_to_list(Port)),
    {ok, L} = csp_link:open(T, csp_exe(), []), track(L),
    Said = link_said(nomatch),
    expect("a node's program is read from its dumps",
	   string:find(Said, "declarations") =/= nomatch, Said),
    Listed = receive {csp_program, Text} -> Text after 3000 -> "" end,
    expect("and comes back as source, listed off its image",
	   string:find(Listed, "#Cnt a") =/= nomatch andalso
	   string:find(Listed, "K=K+1 ? timeout(T)") =/= nomatch, Listed),
    csp_link:tick(L),
    V1 = node_state(),
    expect("a node's state reads by name, objects and signs right",
	   maps:get("a.N", V1, x) =/= x andalso maps:get("b.N", V1, x) =/= x
	   andalso maps:get("Neg", V1) =:= -5
	   andalso maps:get("Big", V1) =:= 16#FFFFFFF0, V1),
    csp_link:pause(L),
    csp_link:tick(L),
    {C1, P1} = node_cycle(),
    csp_link:step(L, 3),
    {C2, P2} = node_cycle(),
    expect("stepping a node runs that many cycles and reads them",
	   C2 =:= C1 + 3 andalso
	   maps:get("b.N", P2) =:= (maps:get("b.N", P1) + 6) band 255,
	   {C1, C2, P1, P2}),
    csp_link:close(L).

%% The chat's own parts, without a model: its tools are well formed, the
%% manual answers, `check' says what csp says, and the panel's half keeps a
%% node out of the chat's hands unless candid.config lets it in.
chat_checks() ->
    Tools = csp_chat:tools(),
    expect("chat: every tool has a name, a description and an object schema",
	   lists:all(fun(#{name := N, description := D,
			   schema := #{type := <<"object">>}}) ->
			     is_binary(N) andalso is_binary(D);
			(_) -> false
		     end, Tools), length(Tools)),
    Man = lists:flatten(io_lib:format("~ts", [csp_chat:manual(tree(""), <<"timer period">>)])),
    expect("chat: the manual answers a query", string:find(Man, "#timer") =/= nomatch,
	   string:slice(Man, 0, 80)),
    Info = #{exe => csp_exe()},
    Good = csp_chat:check(Info, <<"#digital Led out 0:13\nLed = 1\n">>),
    {error, Bad} = csp_chat:check(Info, <<"#variable X = 0\nX = X +\nY = 1\n">>),
    BadS = lists:flatten(io_lib:format("~ts", [Bad])),
    expect("chat: check says ok, or the line csp complains about",
	   Good =:= ok andalso string:find(BadS, "program:2") =/= nomatch, BadS),
    Node = #{last => #{"X" => 1}, clock => {7, 0}, mode => run, local => false,
	     link => none},
    expect("chat: a node is not driven unless candid.config says so",
	   element(1, csp_chat:panel_tool(<<"set">>, #{<<"name">> => <<"X">>,
						       <<"value">> => 2}, Node))
	   =:= error, nomatch),
    {ok, St} = csp_chat:panel_tool(<<"state">>, #{}, Node),
    expect("chat: the state reads with its cycle",
	   string:find(lists:flatten(io_lib:format("~s", [St])), "cycle 7") =/= nomatch,
	   St),
    Ctx = #{chat => self(), panel => self(), made => [],
	    info => #{file => "demo/gate.csp", root => tree(""),
		      exe => csp_exe(), demo_dir => "demo"}},
    Turn = csp_chat:converse([#{role => user, content => <<"hej">>}], Ctx,
			     #{backend => fake_llm}),
    Last = case Turn of
	       {ok, All} -> maps:get(content, lists:last(All));
	       Other -> Other
	   end,
    expect("chat: a turn runs the tools and comes back with the answer",
	   Last =:= <<"check said: ok">>, Last),
    expect("chat: stepping a running program asks to pause first",
	   element(1, csp_chat:panel_tool(<<"step">>, #{},
					  Node#{local := true})) =:= error,
	   nomatch).

relay(LS) ->
    {ok, S} = gen_tcp:accept(LS),
    inet:setopts(S, [{active, true}]),
    P = open_port({spawn_executable, csp_exe()},
		  [{args, ["-i", "--no-eeprom", "-e", "/tmp/candid_none.db",
			   tree("tests/dump/node.csp")]},
		   use_stdio, stderr_to_stdout, {line, 4096}, exit_status]),
    relay(S, P).

relay(S, P) ->
    receive
	{tcp, S, Line} -> port_command(P, Line), relay(S, P);
	{P, {data, {_, Line}}} -> gen_tcp:send(S, [Line, "\n"]), relay(S, P);
	{tcp_closed, S} -> port_command(P, "/quit\n");
	{P, {exit_status, _}} -> gen_tcp:close(S)
    end.

%% A node on a serial line: csp --uart=pty makes the pair and names the far
%% end, its console is routed to that uart (examples/uart_serv.csp), and the
%% link opens the far end. What a board's second uart would be, with nothing
%% plugged in. Skipped where the uart application is not on the code path.
uart_checks() ->
    case code:which(uart) of
	non_existing -> io:format("SKIP  uart: no uart application~n");
	_ -> uart_checks1()
    end.

uart_checks1() ->
    flush(),
    Node = open_port({spawn_executable, csp_exe()},
		     [{args, ["-i", "--no-eeprom", "-e", "/tmp/candid_none.db",
			      "--uart=pty", tree("tests/dump/node.csp"),
			      tree("examples/uart_serv.csp")]},
		      use_stdio, stderr_to_stdout, {line, 256}, exit_status]),
    Far = receive {Node, {data, {eol, "uart 0: " ++ P}}} -> P
	  after 3000 -> none
	  end,
    expect("csp --uart=pty names the far end", Far =/= none, Far),
    {ok, T} = csp_link:target(Far),
    {ok, L} = csp_link:open(T, csp_exe(), []), track(L),
    Said = link_said(nomatch),
    expect("a node on a serial line: its program is read",
	   string:find(Said, "+ the patch running") =/= nomatch, Said),
    csp_link:pause(L),
    csp_link:tick(L),
    {C1, P1} = node_cycle(),
    csp_link:step(L, 3),
    {C2, P2} = node_cycle(),
    expect("and it steps and reads over the line",
	   C1 =/= none andalso C2 =:= C1 + 3 andalso
	   maps:get("b.N", P2) =:= (maps:get("b.N", P1) + 6) band 255,
	   {C1, C2, P1, P2}),
    csp_link:close(L),
    port_command(Node, "/quit\n"),
    receive {Node, {exit_status, _}} -> ok after 2000 -> ok end.

link_said(Last) ->
    receive
	{csp_link, Text} ->
	    T = lists:flatten(Text),
	    case string:find(T, "reading") of
		nomatch -> T;
		_ -> link_said(T)
	    end
    after 3000 -> Last
    end.

node_state() ->
    receive
	{csp_state, _, Vals} -> maps:from_list(Vals)
    after 3000 -> #{}
    end.

%% The last state, once they stop coming: a step is asked about until done.
node_cycle() ->
    receive
	{csp_state, C, Vals} -> node_cycle({C, maps:from_list(Vals)})
    after 3000 -> {none, #{}}
    end.

node_cycle(Last) ->
    receive
	{csp_state, C, Vals} -> node_cycle({C, maps:from_list(Vals)})
    after 300 -> Last
    end.

analog_checks() ->
    Cpx = tree("examples/cpx_ball.csp"),
    case filelib:is_regular(Cpx) of
	false -> io:format("skip  analog (no cpx_ball.csp)~n");
	true ->
	    {ok, A} = candyspeak:parse(Cpx),
	    Ws = candid:widgets(A),
	    expect("analog in becomes a slider with the declared width",
		   lists:member({slider, "Light", 10}, Ws), Ws),
	    expect("port 9 becomes a pixel",
		   lists:member({pixel, "P0", 16}, Ws), Ws)
    end,
    expect("rgb565 decodes the strip",
	   lists:flatten(candid:rgb565(16#F800)) =:= "rgb(255,0,0)" andalso
	   lists:flatten(candid:rgb565(16#001F)) =:= "rgb(0,0,255)",
	   {candid:rgb565(16#F800), candid:rgb565(16#001F)}).

%% No widgets to poke: open the link, tick it, and watch the lamps move.
traffic_check() ->
    F = tree("examples/traffic.csp"),
    case filelib:is_regular(F) of
	false -> io:format("skip  traffic (not found)~n");
	true ->
	    {ok, L} = csp_link:open(csp_exe(), [F]), track(L),
	    Seen = tick_collect(L, 40, []),
	    csp_link:close(L),
	    timer:sleep(300),
	    expect("timer-driven program changes with no input",
		   length(lists:usort(Seen)) > 1, lists:usort(Seen))
    end.

tick_collect(_L, 0, Acc) -> Acc;
tick_collect(L, N, Acc) ->
    csp_link:tick(L),
    Acc1 = receive
	       {csp_state, _, Vals} ->
		   [[{K, V} || {K, V} <- Vals,
			       lists:member(K, ["Red","Yellow","Green"])] | Acc]
	   after 300 -> Acc
	   end,
    tick_collect(L, N - 1, Acc1).

%% A file of candyspeak's tree: the Makefile exports CANDYSPEAK.
tree(P) ->
    filename:join(os:getenv("CANDYSPEAK", filename:join(os:getenv("HOME"),
							"work/candyspeak")), P).

csp_exe() ->
    case os:getenv("CSP_EXE") of
	false -> tree("csp");
	Path  -> Path
    end.

latch_file() ->
    F = "demo/latch.csp",
    case filelib:is_regular(F) of true -> F; false -> "demo/gate.csp" end.

%% The chooser's event is created first, before any switch.
first_event() ->
    [Id | _] = [list_to_integer(string:trim(string:prefix(X, "event ")))
		|| X <- calls(), lists:prefix("event ", X)],
    Id.

%% One batched call per tick, not one fillRect per trace: the column is handed
%% to a painter function created once in the browser. See candid:painter/1 --
%% wse:set/4 is rsync, so the old shape cost a round trip per trace per tick.
samples(L) -> [X || X <- L, lists:prefix("ASYNC cast call", X)].

calls() ->
    wse_log ! {calls, self()},
    receive {calls, L} -> L after 1000 -> [] end.

expect(What, true, _)  -> io:format("ok    ~s~n", [What]);
expect(What, false, D) ->
    io:format("FAIL  ~s: ~p~n", [What, D]),
    %% halt/1 runs no `after' clause and no linked process's cleanup, so a
    %% csp started by this test would be left holding a pipe nobody closes --
    %% and --exit-on-eof does not help, because the VM never closes it. Every
    %% link opened here is registered; close them before going.
    close_links(),
    halt(1).

%% Links opened by the test, so a failure can still take them down. A process
%% dictionary rather than an argument: expect/3 is called from a dozen places
%% and none of them should have to carry the bookkeeping.
track(L) ->
    put(links, [L | get_or([])]),
    L.

%% The panel process owns a link of its own, so it has to come down too -- it
%% is sent `stop', which is what makes its csp_link send /quit.
track_panel(P) ->
    put(panels, [P | case get(panels) of undefined -> []; V -> V end]),
    P.

get_or(D) -> case get(links) of undefined -> D; V -> V end.

close_links() ->
    [catch (P ! stop) || P <- case get(panels) of undefined -> []; V -> V end],
    [catch csp_link:close(L) || L <- get_or([])],
    timer:sleep(400),          % give each one time to send /quit
    put(links, []),
    put(panels, []).

logger(Acc) ->
    receive
	{log, S}        -> logger([lists:flatten(S) | Acc]);
	{calls, From}   -> From ! {calls, lists:reverse(Acc)}, logger(Acc)
    end.

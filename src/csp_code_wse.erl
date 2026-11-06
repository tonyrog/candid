%%% The code view's renderer for the browser: csp_code decides what the view
%%% shows, this writes it as html and lights it through wse.
%%%
%%% THE CONTRACT is the ids and the classes. csp_code names every piece --
%%% a rule's row r<N>, its coil k<N>, its contacts k<N>_<I> in walk order, a
%%% gate header g<I>, a trace cell tr_<Col>_<Step>, a signal sl_<N> / sv_<N>,
%%% a value m_<N> / v_<N>, csp_st -- and paints them with class names: ct t
%%% (holds), ct u (cannot tell), co nx (will fire), co on (fired), rw off (its
%%% block is not in force), hd t, mt / mf (marked), sgt / sgf, cur, bad, any.
%%% A renderer builds the pieces under those ids and shows the classes in its
%%% own way; css/1 is this one's.
%%%
%%% The rungs are the exception: csp_ladder lays them out and colours them by
%%% their classes, and this only draws its ops on a <canvas>. A click on it
%%% comes back as `xy=X,Y'.

-module(csp_code_wse).

-define(FONT, "13px monospace").
-define(LINE_H, 16).                      % px, a line of ?FONT

-export([new/4, metrics/2, shown/3, rungs/6, draw/3, paint/4, goal/3,
	 answer/5]).


css(C) ->
    Fill = fun(K) -> ["color-mix(in srgb,", maps:get(K, C), " 25%,#111)"] end,
    Ink = fun(K) -> ["color-mix(in srgb,", maps:get(K, C), " 35%,#fff)"] end,
    Col = fun(K) -> maps:get(K, C) end,
    lists:flatten(
      [".cv{font:13px monospace;color:#bbb}"
       ".cv .bar button{font:12px monospace;padding:2px 8px;margin:0 4px 8px 0;"
       "  border:1px solid #555;background:#333;color:#ccc}"
       ".cv .bar button.sel{background:#3af;color:#111;font-weight:bold}"
       %% A table: the cells share their borders, one line between two.
       ".vals{display:grid;grid-template-columns:repeat(auto-fill,"
       "  minmax(150px,1fr));margin:0 1px 10px 0;color:#888;"
       "  font:13px monospace}"
       ".vals span{border:1px solid #3a3a3a;margin:0 -1px -1px 0;"
       "  padding:2px 8px}"
       ".vals b{color:#ddd;font-weight:normal;float:right}"
       ".vals i{color:#8ab}"
       %% The model frame, in the panel's top: goal, solve, the answer.
       ".md{font:13px monospace;color:#bbb}"
       ".md button,.md select{font:12px monospace;padding:2px 8px;"
       "  margin-left:4px;border:1px solid #555;background:#333;color:#ccc}"
       ".md button+button{margin-left:-1px}"
       ".md .goal{display:inline-block;min-width:320px;padding:3px 10px;"
       "  border:2px solid ", Col(want), ";border-radius:3px;color:#eee;"
       "  background:", Fill(want), "}"
       ".md .goal.none{border-style:dashed;color:#888;background:none}"
       ".md .res{margin:6px 0 4px 0;white-space:pre-wrap;color:#aaa;"
       "  max-height:30vh;overflow:auto}"
       ".md .res.bad{color:", Col(unwant), "}"
       ".md .res.ok{color:", Col(true), "}"
       ".md table{border-collapse:collapse;margin:2px 0 8px 0}"
       ".md td,.md th{border:1px solid #3a3a3a;padding:1px 8px;"
       "  text-align:right}"
       ".md th{color:#8ab;font-weight:normal}"
       ".md td.g{color:", Col(want), "}"
       ".md td.any{color:#555}"
       ".md .hid{display:none}"
       ".md td.cur,.md th.cur{background:", Fill(want), "}"
       ".md td.bad{background:", Fill(unwant), ";color:", Ink(unwant), "}"
       "[data-sig]{cursor:pointer}"
       ".sgt{outline:2px solid ", Col(want), ";outline-offset:1px}"
       ".sgf{outline:2px dashed ", Col(unwant), ";outline-offset:1px}"
       ".cv .bind{color:#8ab;margin-bottom:8px}"
       ".cv canvas{display:block}"]).

%%% ----------------------------------------------------------------- view

%% The view, hidden, with its tab buttons; the model frame (goal, clear,
%% solve, k) in the top frame's row, and the answer and the program's own
%% values below it. Where is what the panel made for it (candid_wse:panel/3);
%% Spec: colours, ks and k (solve's bounds and the one picked). Back: the
%% handles, the event id among them -- what the browser sends on it is
%% `tab=I', `ct=Id', `sig=Name', `clear', `solve', `k=K' and the trace's
%% buttons.
new(Ws, Where, Tabs, #{colours := Colours, ks := Ks, k := K0}) ->
    #{code := Parent, status := Row, top := Top} = Where,
    Style = wse:createElement(Ws, "style"),
    wse:set(Ws, Style, "textContent", candid_wse:u(css(Colours))),
    wse:appendChild(Ws, Parent, Style),
    {ok, Ev} = wse:create_event(Ws),
    Notify = fun(Tag) -> wse:newf(Ws, "", "{ Wse.notify(" ++
				      integer_to_list(Ev) ++ ", " ++ Tag ++
				      "); }")
	     end,
    Box = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Box, "display:none"),
    Bar = wse:createElement(Ws, "div"),
    wse:set(Ws, Bar, "className", "bar"),
    Btns = case Tabs of
	       [_] -> [];
	       _ ->
		   [begin
			B = wse:createElement(Ws, "button"),
			wse:appendChild(Ws, B, wse:createTextNode(Ws, candid_wse:u(Name))),
			wse:set(Ws, B, "onclick",
				Notify("'tab=" ++ integer_to_list(I) ++ "'")),
			wse:appendChild(Ws, Bar, B),
			B
		    end || {I, #{name := Name}} <- enum(Tabs)]
	   end,
    Body = wse:createElement(Ws, "div"),
    Canvas = wse:createElement(Ws, "canvas"),
    wse:appendChild(Ws, Box, Bar),
    wse:appendChild(Ws, Box, Body),
    wse:appendChild(Ws, Box, Canvas),
    wse:appendChild(Ws, Parent, Box),
    %% The model frame: goal, clear, solve within k, and below them the answer
    %% and the values.
    Md = wse:createElement(Ws, "span"),
    wse:set(Ws, Md, "className", "md"),
    Goal = wse:createElement(Ws, "span"),
    wse:appendChild(Ws, Md, Goal),
    [begin
	 B = wse:createElement(Ws, "button"),
	 wse:appendChild(Ws, B, wse:createTextNode(Ws, candid_wse:u(Label))),
	 wse:set(Ws, B, "onclick", Notify("'" ++ Label ++ "'")),
	 wse:appendChild(Ws, Md, B)
     end || Label <- ["clear", "solve"]],
    Sel = wse:createElement(Ws, "select"),
    [begin
	 O = wse:createElement(Ws, "option"),
	 wse:set(Ws, O, "value", K),
	 wse:appendChild(Ws, O, wse:createTextNode(
				  Ws, "k \x{2264} " ++ integer_to_list(K))),
	 K =:= K0 andalso wse:set(Ws, O, "selected", true),
	 wse:appendChild(Ws, Sel, O)
     end || K <- Ks],
    wse:set(Ws, Sel, "onchange", Notify("'k=' + this.value")),
    wse:appendChild(Ws, Md, Sel),
    wse:appendChild(Ws, Row, Md),
    Res = wse:createElement(Ws, "div"),
    wse:set(Ws, Res, "className", "md"),
    wse:appendChild(Ws, Top, Res),
    #{vars := MainVars} = hd(Tabs),
    Vals = wse:createElement(Ws, "div"),
    wse:set(Ws, Vals, "innerHTML", candid_wse:u(lists:flatten(vals("m_", none, MainVars)))),
    wse:appendChild(Ws, Top, Vals),
    Paint = wse:newf(Ws, "a,b",
		     "{ for (var i = 0; i < a.length; i += 2) {"
		     "    var e = document.getElementById(a[i]);"
		     "    if (e) e.className = a[i+1]; }"
		     "  for (var i = 0; i < b.length; i += 2) {"
		     "    var e = document.getElementById(b[i]);"
		     "    if (e) e.textContent = b[i+1]; } }"),
    %% Any element with data-sig is a signal to mark: the devices' labels and
    %% the value cells. One handler on the panel, since the cells come and go
    %% with the tabs.
    Sig = wse:newf(Ws, "",
		   "{ document.getElementById('panel').onclick = function(e) {"
		   "    var t = e.target.closest('[data-sig]');"
		   "    if (t) Wse.notify(" ++ integer_to_list(Ev) ++
		       ", 'sig=' + t.dataset.sig); }; }"),
    wse:cast(Ws, Sig, "call", [null]),
    %% The rungs: csp_ladder's ops, drawn as they come. A click goes back as
    %% `xy=X,Y', and csp_code says what is there.
    Draw = wse:newf(Ws, "c,w,h,ops",
		    "{ var r = window.devicePixelRatio || 1;"
		    "  if (w >= 0) { c.width = w * r; c.height = h * r;"
		    "    c.style.width = w + 'px'; c.style.height = h + 'px';"
		    "    c.onclick = function(e) {"
		    "      var b = c.getBoundingClientRect();"
		    "      Wse.notify(" ++ integer_to_list(Ev) ++ ", 'xy=' +"
		    "        Math.round(e.clientX - b.left) + ',' +"
		    "        Math.round(e.clientY - b.top)); }; }"
		    "  var x = c.getContext('2d');"
		    "  x.setTransform(r, 0, 0, r, 0, 0);"
		    "  x.clearRect(0, 0, c.width, c.height);"
		    "  x.font = '" ++ ?FONT ++ "'; x.textBaseline = 'top';"
		    "  JSON.parse(ops).forEach(function(o) {"
		    "    x.setLineDash(o[o.length - 1] ? [3, 3] : []);"
		    "    if (o[0] == 'r') {"
		    "      x.beginPath(); x.roundRect(o[1], o[2], o[3], o[4], o[5]);"
		    "      if (o[6]) { x.fillStyle = o[6]; x.fill(); }"
		    "      if (o[7]) { x.lineWidth = 1; x.strokeStyle = o[7];"
		    "                  x.stroke(); } }"
		    "    else if (o[0] == 'l') {"
		    "      x.beginPath(); x.moveTo(o[1], o[2]); x.lineTo(o[3], o[4]);"
		    "      x.lineWidth = o[6]; x.strokeStyle = o[5]; x.stroke(); }"
		    "    else {"
		    "      x.font = (o[5] ? 'bold ' : '') + '" ++ ?FONT ++ "';"
		    "      x.fillStyle = o[4]; x.fillText(o[3], o[1], o[2]); } }); }"),
    #{box => Box, body => Body, canvas => Canvas, draw => Draw,
      tab_buttons => Btns, event => Ev, paint => Paint, goal => Goal,
      res => Res}.

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).

%% The view shown or not.
shown(Ws, #{box := Box}, Show) ->
    wse:setStyle(Ws, Box, case Show of
			      true  -> "display:block";
			      false -> "display:none"
			  end).

%% The width of a character and the height of a line in ?FONT, which the
%% layout is made of (csp_ladder).
metrics(Ws, _H) ->
    F = wse:newf(Ws, "", "{ var x = document.createElement('canvas')"
		 ".getContext('2d'); x.font = '" ++ ?FONT ++ "';"
		 "  return Math.round(x.measureText('MMMMMMMMMM').width * 100); }"),
    {ok, W} = wse:call(Ws, F, "call", [null]),
    #{cw => W / 1000, ch => ?LINE_H}.

%% Tab I: its buttons, an object's bindings and values, and the canvas the
%% rungs are drawn on, Size big. Tab is csp_code's.
rungs(Ws, #{box := Box, body := Body, tab_buttons := Btns, canvas := C,
	    draw := D}, _Mode, I, Tab, {W, H}) ->
    wse:set(Ws, Box, "className", "cv"),
    [wse:set(Ws, B, "className", case J of I -> "sel"; _ -> "" end)
     || {J, B} <- enum(Btns)],
    wse:set(Ws, Body, "innerHTML", candid_wse:u(lists:flatten(head(Tab)))),
    wse:cast(Ws, D, "call", [null, C, W, H, "[]"]).

%% csp_ladder's ops, the whole picture.
draw(Ws, #{canvas := C, draw := D}, Ops) ->
    wse:cast(Ws, D, "call", [null, C, -1, -1, json(Ops)]).

%% As its UTF-8 bytes: what wse sends as a string (candid_wse:u/1).
json(Ops) ->
    binary_to_list(iolist_to_binary(json:encode([op(O) || O <- Ops]))).

op({rect, X, Y, W, H, R, F, S, D}) ->
    [<<"r">>, X, Y, W, H, R, rgb(F), rgb(S), D];
op({line, X1, Y1, X2, Y2, C, W, D}) ->
    [<<"l">>, X1, Y1, X2, Y2, rgb(C), W, D];
op({text, X, Y, T, C, B}) ->
    [<<"t">>, X, Y, unicode:characters_to_binary(T), rgb(C), B, false].

rgb(none) -> false;
rgb({R, G, B}) ->
    iolist_to_binary(io_lib:format("rgb(~w,~w,~w)", [R, G, B])).

%% The classes and texts that changed: [Id, Class ...], [Id, Text ...].
paint(Ws, #{paint := F}, Cs, Ts) ->
    wse:cast(Ws, F, "call", [null, wse:array(Cs), wse:array(Ts)]).

%% An object's bindings and its values. The program's own values are in the
%% top frame, where they stay in view.
head(#{binds := none}) ->
    "";
head(Tab = #{binds := {M, Bs}, vars := Vars, prefix := P}) ->
    [["<div class='bind'>#", M, " ", maps:get(name, Tab), " ",
      esc(lists:join("  ", [csp_code:bind(B) || B <- Bs])), "</div>"],
     vals("v_", P, Vars)].

%% The values with no widget of their own, as a table; a #local in italics.
%% A cell is a signal to mark (data-sig), by its whole name.
vals(_Pre, _Obj, []) -> "";
vals(Pre, Obj, Vars) ->
    ["<div class='vals'>",
     [begin
	  Full = case Obj of none -> N; _ -> Obj ++ "." ++ N end,
	  ["<span data-sig='", Full, "' id='sv_", Full, "'>",
	   case K of local -> ["<i>", N, "</i>"]; var -> N end,
	   "<b id='", Pre, N, "'></b></span>"]
      end || {K, N} <- Vars],
     "</div>"].

esc(T) ->
    lists:flatmap(fun($<) -> "&lt;";
		     ($>) -> "&gt;";
		     ($&) -> "&amp;";
		     (C)  -> [C]
		  end, lists:flatten(T)).

buttons(Ev, Tags) ->
    [["<button onclick=\"Wse.notify(", integer_to_list(Ev), ",'", T, "')\">",
      case T of
	  "rstep" -> "step";
	  "up"    -> "&#9650;";
	  "down"  -> "&#9660;";
	  _       -> T
      end, "</button>"] || T <- Tags].

%% varp's answer: Cls is ok, bad or "" (asking), and with a trace found its
%% buttons, the line the walk writes (tr_ev) and the table (tr_tab).
answer(Ws, H = #{res := R}, Cls, Text, Trace) ->
    Table = case Trace of
		none -> "";
		{Rows, M, Names} ->
		    ["\n", buttons(maps:get(event, H),
				   ["up", "down", "live", "table", "replay", "rstep"]),
		     " <span id='tr_ev'></span>",
		     "<div id='tr_tab'>", table(Rows, M, Names), "</div>"]
	    end,
    wse:set(Ws, R, "className", "md res " ++ Cls),
    wse:set(Ws, R, "innerHTML", candid_wse:u(lists:flatten([esc(Text), Table]))).

%% The trace, a column per step. The abstracted guards become `L26?', the
%% choice of whether that rule may fire; St is shown by name.
table(Rows, M = #{states := Sts}, Names) ->
    Cols = csp_code:cols(Rows),
    Steps = lists:seq(0, length(Rows) - 1),
    Id = fun(C, I) -> [" id='", csp_code:tr_id(C, I), "'"] end,
    ["<table><tr><th></th>",
     [["<th", Id(step, I), ">", integer_to_list(I), "</th>"] || I <- Steps],
     "</tr>",
     [["<tr><th>", esc(csp_code:col_name(C)), "</th>",
       [cell(C, csp_code:signed(C, proplists:get_value(C, R), M), Sts, Names,
	     Id(C, I))
	|| {I, R} <- lists:zip(Steps, Rows)],
       "</tr>"] || C <- Cols],
     "</table>"].


cell(_C, '-', _Sts, _Names, Id) -> ["<td class='any'", Id, ">-</td>"];
cell("St", V, Sts, Names, Id) ->
    ["<td", Id, ">", case lists:keyfind(V, 2, Sts) of
			 {N, V} -> N;
			 false  -> maps:get(V, Names, integer_to_list(V))
		     end, "</td>"];
cell(_C, V, _Sts, _Names, Id) when is_integer(V) ->
    ["<td", Id, ">", integer_to_list(V), "</td>"];
cell(_C, V, _Sts, _Names, Id) ->
    ["<td", Id, ">", esc(V), "</td>"].

%% The goal the marks add up to, or none.
goal(Ws, #{goal := G}, none) ->
    wse:set(Ws, G, "className", "goal none"),
    wse:set(Ws, G, "textContent",
	    "goal: click a contact -- holds, does not, forget");
goal(Ws, #{goal := G}, Text) ->
    wse:set(Ws, G, "className", "goal"),
    wse:set(Ws, G, "textContent", candid_wse:u("goal: " ++ Text)).

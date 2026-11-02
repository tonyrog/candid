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

-module(csp_code_wse).

-export([new/4, shown/3, rungs/5, paint/4, goal/3, answer/5]).


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
       ".cv .rw{display:flex;align-items:center;margin:3px 0;flex-wrap:nowrap}"
       ".cv .ln{color:#555;width:3.2em;text-align:right;margin-right:10px;"
       "  flex:none}"
       ".cv .and{display:flex;align-items:center}"
       ".cv .or{display:flex;flex-direction:column;border-left:2px solid #666;"
       "  border-right:2px solid #666;padding:1px 0}"
       ".cv .br{display:flex;align-items:center;justify-content:space-between}"
       ".cv .br>.w:last-child{flex:1}"
       ".cv .w{display:inline-block;height:2px;min-width:10px;background:#666}"
       ".cv .ct{border:1px solid #555;padding:1px 6px;border-radius:3px;"
       "  background:#1e1e1e;color:#999;white-space:nowrap;cursor:pointer}"
       ".cv .ct.t{background:", Fill(true), ";border-color:", Col(true),
       ";color:", Ink(true), ";box-shadow:0 0 6px ", Col(true), "}"
       ".cv .ct.u{border-style:dashed;color:#666}"
       %% A mark is the frame: the fill still says what holds now.
       ".cv .ct.mt{outline:2px solid ", Col(want), ";outline-offset:2px}"
       ".cv .ct.mf{outline:2px dashed ", Col(unwant), ";outline-offset:2px}"
       ".cv .co{border:1px solid #555;border-radius:10px;padding:1px 9px;"
       "  color:#999;white-space:nowrap}"
       ".cv .co.nx{border-color:", Col(next), ";color:", Ink(next), "}"
       ".cv .co.on{background:", Fill(fired), ";border-color:", Col(fired),
       ";color:", Ink(fired), ";box-shadow:0 0 7px ", Col(fired), "}"
       ".cv .hd{color:#68a;margin:10px 0 2px 0}"
       ".cv .rw.off{opacity:0.35}"
       ".cv .hd.e{color:#456;margin:2px 0 8px 0}"
       ".cv .hd.t{color:", Col(block), ";font-weight:bold}"
       ".cv.code .ct{border:none;padding:0 2px;background:none;box-shadow:none}"
       ".cv.code .ct.t{color:", Col(true), ";text-shadow:0 0 5px ", Col(true), "}"
       ".cv.code .ct.u{color:#666;text-decoration:underline dotted}"
       ".cv.code .co{border:none;padding:0 2px}"
       ".cv.code .co.on{background:", Fill(fired), "}"
       ".cv.code .op{color:#777}"
       ".cv .tx{white-space:pre}"]).

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
    wse:set(Ws, Style, "textContent", css(Colours)),
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
			wse:appendChild(Ws, B, wse:createTextNode(Ws, Name)),
			wse:set(Ws, B, "onclick",
				Notify("'tab=" ++ integer_to_list(I) ++ "'")),
			wse:appendChild(Ws, Bar, B),
			B
		    end || {I, #{name := Name}} <- enum(Tabs)]
	   end,
    Body = wse:createElement(Ws, "div"),
    wse:appendChild(Ws, Box, Bar),
    wse:appendChild(Ws, Box, Body),
    wse:appendChild(Ws, Parent, Box),
    %% The model frame: goal, clear, solve within k, and below them the answer
    %% and the values.
    Md = wse:createElement(Ws, "span"),
    wse:set(Ws, Md, "className", "md"),
    Goal = wse:createElement(Ws, "span"),
    wse:appendChild(Ws, Md, Goal),
    [begin
	 B = wse:createElement(Ws, "button"),
	 wse:appendChild(Ws, B, wse:createTextNode(Ws, Label)),
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
    wse:set(Ws, Vals, "innerHTML", lists:flatten(vals("m_", none, MainVars))),
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
    #{box => Box, body => Body, tab_buttons => Btns, event => Ev,
      paint => Paint, goal => Goal, res => Res}.

enum(L) -> lists:zip(lists:seq(0, length(L) - 1), L).

%% The view shown or not.
shown(Ws, #{box := Box}, Show) ->
    wse:setStyle(Ws, Box, case Show of
			      true  -> "display:block";
			      false -> "display:none"
			  end).

%% Tab I's rungs, drawn as ladder or code. Tab is csp_code's: its rules, env,
%% prefix, binds and vars.
rungs(Ws, H = #{box := Box, body := Body, tab_buttons := Btns}, Mode, I, Tab) ->
    wse:set(Ws, Box, "className", case Mode of
				      ladder -> "cv";
				      code   -> "cv code"
				  end),
    [wse:set(Ws, B, "className", case J of I -> "sel"; _ -> "" end)
     || {J, B} <- enum(Btns)],
    Html = lists:flatten([head(Tab), html(maps:get(rules, Tab), Mode,
					   #{env => maps:get(env, Tab),
					     prefix => maps:get(prefix, Tab),
					     event => maps:get(event, H)})]),
    wse:set(Ws, Body, "innerHTML", Html).

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

%%% ----------------------------------------------------------------- html
%%%
%%% Ids: a rule's coil is k<N>, its contacts k<N>_<I> in walk order, a gate
%%% header g<I>. paint/2 sets classes by id, so the html is written once.

html(Rules, Mode, V) ->
    {Out, _} = lists:mapfoldl(fun(R, G) -> row(R, G, Mode, V) end, 0, Rules),
    Out.

row({gate, 'end', _}, G, _Mode, _V) ->
    {"<div class='hd e'>#end</div>", G};
row({gate, Kind, Arg}, G, _Mode, _V) ->
    T = case Kind of
	    in      -> ["#in ", lists:join(" ", Arg)];
	    'when'  -> ["#when ", candyspeak_eval:text(Arg)]
	end,
    {["<div class='hd' id='g", integer_to_list(G), "'>", esc(T), "</div>"],
     G + 1};
row(R = #{no := N, line := Ln, guard := Gd, assigns := As}, G, Mode, V) ->
    K = "k" ++ integer_to_list(N),
    Label = case {Mode, R} of
		{ladder, #{coil := Tgt}} -> candyspeak_eval:text(Tgt);
		{code, #{coil := Tgt}}   -> [candyspeak_eval:text(Tgt), " ="];
		_ -> lists:join(", ", [csp_code:assign(A) || A <- As])
	    end,
    Coil = ["<span class='co' id='", K, "'>", esc(Label), "</span>"],
    Ln1 = ["<span class='ln'>", integer_to_list(Ln), "</span>"],
    Body = case {Mode, Gd} of
	       {ladder, undefined} ->
		   [Ln1, "<span class='w' style='width:40px'></span>", Coil];
	       {ladder, _} ->
		   {L, _} = ladder(Gd, K, 0, V),
		   [Ln1, "<span class='w'></span>", L,
		    "<span class='w'></span>", Coil];
	       {code, undefined} ->
		   [Ln1, "<span class='tx'>", Coil, "</span>"];
	       {code, _} ->
		   {T, _} = code(Gd, K, 0, 0, V),
		   Sep = case R of
			     #{coil := _} -> "&nbsp;";
			     _ -> "<span class='op'>&nbsp;?&nbsp;</span>"
			 end,
		   %% one inline run: as flex items the operators would
		   %% lose the spaces around them
		   [Ln1, "<span class='tx'>", Coil, Sep, T, "</span>"]
	   end,
    {["<div class='rw' id='r", integer_to_list(N), "'>", Body, "</div>"], G}.


%% AND horizontal, OR vertical. Returns {Html, NextContact}.
ladder(X = {'&&', _, _, _}, K, I, V) ->
    {Hs, I1} = lists:mapfoldl(fun(C, J) -> ladder(C, K, J, V) end, I,
			      csp_code:chain('&&', X)),
    {["<span class='and'>", lists:join("<span class='w'></span>", Hs),
      "</span>"], I1};
ladder(X = {'||', _, _, _}, K, I, V) ->
    {Hs, I1} = lists:mapfoldl(fun(C, J) -> ladder(C, K, J, V) end, I,
			      csp_code:chain('||', X)),
    {["<span class='or'>",
      [["<span class='br'>", H, "<span class='w'></span></span>"] || H <- Hs],
      "</span>"], I1};
ladder(X, K, I, V) ->
    {contact(X, K, I, V), I + 1}.

%% The same walk as text: the contacts in order, the operators between.
code(X = {Op, _, _, _}, K, I, P, V) when Op =:= '&&'; Op =:= '||' ->
    Q = case Op of '||' -> 1; '&&' -> 2 end,
    {Ts, I1} = lists:mapfoldl(fun(C, J) -> code(C, K, J, Q + 1, V) end, I,
			      csp_code:chain(Op, X)),
    T = lists:join(["<span class='op'> ", atom_to_list(Op), " </span>"], Ts),
    {case Q < P of
	 true  -> ["<span class='op'>(</span>", T, "<span class='op'>)</span>"];
	 false -> T
     end, I1};
code(X, K, I, _P, V) ->
    {contact(X, K, I, V), I + 1}.


%% A contact. A click marks it, see control/3.
contact(X, K, I, #{event := Ev}) ->
    Id = [K, "_", integer_to_list(I)],
    ["<span class='ct' id='", Id, "' onclick=\"Wse.notify(",
     integer_to_list(Ev), ",'ct=", Id, "')\">",
     esc(candyspeak_eval:text(X)), "</span>"].

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
    wse:set(Ws, R, "innerHTML", lists:flatten([esc(Text), Table])).

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
    wse:set(Ws, G, "textContent", "goal: " ++ Text).

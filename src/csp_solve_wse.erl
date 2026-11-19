%%% The solver's pane for the browser, through wse: in the panel's dock
%%% (candid_wse). csp_solve proves, this shows it.

-module(csp_solve_wse).

-export([pane/4, show/3, results/3, busy/3, event/2]).

%% Hidden until show/3. Its events go to the process that makes it.
pane(Ws, Title, Ks, K0) ->
    {Box, Close} = candid_wse:dock_pane(Ws, Title, right),
    Text = el(Ws, Box, "textarea", "flex:1;resize:none;font:13px monospace;"
	      "background:#111;color:#eee;border:none;padding:6px 8px"),
    wse:set(Ws, Text, "title", "a line: assume | invariant | reach, then a "
	    "condition on one cycle -- X what it reads, X' what it leaves, "
	    "A => B; // a comment"),
    wse:set(Ws, Text, "id", "csp_solve_text"),
    Foot = el(Ws, Box, "div", "display:flex;gap:6px;padding:4px 8px;"
	      "border-top:1px solid #333;align-items:center"),
    {ok, Ev} = wse:create_event(Ws),
    %% prove says the lines and k with it: one message, nothing in between
    B = el(Ws, Foot, "button", lists:flatten(candid_wse:btn_style(false))),
    wse:appendChild(Ws, B, wse:createTextNode(Ws, "prove")),
    Sel = el(Ws, Foot, "select", "font:13px monospace;background:#333;"
	     "color:#ccc;border:1px solid #555"),
    wse:set(Ws, Sel, "id", "csp_solve_k"),
    [begin
	 O = wse:createElement(Ws, "option"),
	 wse:set(Ws, O, "value", integer_to_list(K)),
	 K =:= K0 andalso wse:set(Ws, O, "selected", true),
	 wse:appendChild(Ws, O, wse:createTextNode(
				  Ws, candid_wse:u("k \x{2264} " ++
						       integer_to_list(K)))),
	 wse:appendChild(Ws, Sel, O)
     end || K <- Ks],
    wse:set(Ws, B, "onclick",
	    wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Ev) ++
		     ", 'prove=' + document.getElementById('csp_solve_k').value"
		     " + ';' + document.getElementById('csp_solve_text').value); }")),
    Busy = el(Ws, Foot, "span", "color:#fb3;min-width:2em"),
    Res = el(Ws, Box, "div", "flex:1;overflow:auto;padding:4px 8px;"
	     "white-space:pre;font-size:12px;border-top:1px solid #333"),
    #{box => Box, ev => Ev, close => Close, busy => Busy, res => Res}.

show(Ws, #{box := Box}, On) ->
    candid_wse:dock_show(Ws, Box, On).

%% What the person did.
event(#{ev := Id}, {notify, Id, _, "prove=" ++ Data}) ->
    [K, Text] = string:split(Data, ";"),
    {prove, Text, list_to_integer(K)};
event(#{ev := Id}, {notify, Id, _, "pick=" ++ I}) -> {pick, list_to_integer(I)};
event(#{close := Id}, {notify, Id, _, _})         -> close;
event(_P, _Msg)                                   -> none.

%% A row a line: its number, its kind and condition, the answer. One with a
%% trace shows it on a click.
results(Ws, #{res := Res, ev := Ev}, Rows) ->
    wse:set(Ws, Res, "textContent", ""),
    [begin
	 A = el(Ws, Res, "div", "color:#aaa;margin-top:4px"),
	 wse:appendChild(Ws, A, wse:createTextNode(
				  Ws, candid_wse:u(io_lib:format("~3w  ~-9s ~s",
								 [I, Kind, Text])))),
	 B = el(Ws, Res, "div", "color:" ++ colour(Cls) ++ ";padding-left:5em" ++
		    case Tr of true -> ";cursor:pointer"; false -> "" end),
	 wse:appendChild(Ws, B, wse:createTextNode(
				  Ws, candid_wse:u(Answer ++
						       case Tr of
							   true -> "   \x{25B8} show";
							   false -> ""
						       end))),
	 Tr andalso wse:set(Ws, B, "onclick",
			    wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Ev) ++
				     ", 'pick=" ++ integer_to_list(I) ++ "'); }"))
     end || {I, Kind, Text, Cls, Answer, Tr} <- Rows],
    ok.

busy(Ws, #{busy := B}, On) ->
    wse:set(Ws, B, "textContent", case On of true -> "..."; false -> "" end).

colour("ok")  -> "#7d7";
colour("bad") -> "#f77";
colour(_)     -> "#db6".

el(Ws, Parent, Tag, Style) ->
    E = wse:createElement(Ws, Tag),
    wse:setStyle(Ws, E, Style),
    wse:appendChild(Ws, Parent, E),
    E.

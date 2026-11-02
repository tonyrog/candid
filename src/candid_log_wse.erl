%%% The log's pane for the browser, through wse: the left of the panel's dock
%%% (candid_wse). candid_log keeps it, this shows it.

-module(candid_log_wse).

-export([pane/2, show/3, add/4, trim/3, clear/2, event/2]).

%% Hidden until show/3. Its events go to the process that makes it.
pane(Ws, Title) ->
    {Box, Close} = candid_wse:dock_pane(Ws, Title, left),
    Log = el(Ws, Box, "div", "flex:1;overflow:auto;padding:4px 8px;"
	     "font-size:12px;white-space:pre-wrap;word-break:break-word"),
    Foot = el(Ws, Box, "div", "display:flex;justify-content:flex-end;"
	      "padding:2px 8px;border-top:1px solid #333"),
    {ok, Clear} = wse:create_event(Ws),
    B = el(Ws, Foot, "button", "font:12px monospace"),
    wse:appendChild(Ws, B, wse:createTextNode(Ws, "clear")),
    wse:set(Ws, B, "onclick", wse:newf(Ws, "", "{ Wse.notify(" ++
					     integer_to_list(Clear) ++
					     ", 'x'); }")),
    Scroll = wse:newf(Ws, "e", "{ e.scrollTop = e.scrollHeight; }"),
    Trim = wse:newf(Ws, "e, n", "{ while (n-- > 0 && e.firstChild)"
		    " e.removeChild(e.firstChild); }"),
    #{box => Box, log => Log, clear => Clear, close => Close,
      scroll => Scroll, trim => Trim}.

show(Ws, #{box := Box}, On) ->
    candid_wse:dock_show(Ws, Box, On).

add(Ws, #{log := Log, scroll := Scroll}, Kind, Text) ->
    D = el(Ws, Log, "div", "color:" ++ colour(Kind)),
    wse:appendChild(Ws, D, wse:createTextNode(Ws, Text)),
    wse:cast(Ws, Scroll, "call", [null, Log]).

%% The N oldest lines go.
trim(Ws, #{log := Log, trim := Trim}, N) ->
    wse:cast(Ws, Trim, "call", [null, Log, N]).

clear(Ws, P) ->
    trim(Ws, P, 1 bsl 30).

event(#{close := Id}, {notify, Id, _, _}) -> close;
event(#{clear := Id}, {notify, Id, _, _}) -> clear;
event(_P, _Msg)                           -> none.

colour(error)   -> "#f66";
colour(warning) -> "#fb3";
colour(csp)     -> "#cfc";
colour(link)    -> "#9cf";
colour(_)       -> "#aaa".

el(Ws, Parent, Tag, Style) ->
    E = wse:createElement(Ws, Tag),
    wse:setStyle(Ws, E, Style),
    wse:appendChild(Ws, Parent, E),
    E.

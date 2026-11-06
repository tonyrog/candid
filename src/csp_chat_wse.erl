%%% The chat's pane for the browser, through wse: the right of the panel's
%%% dock (candid_wse). csp_chat converses, this shows it.

-module(csp_chat_wse).

-export([pane/2, show/3, say/4, busy/3, event/2]).

%% Hidden until show/3. Its events go to the process that makes it.
pane(Ws, Title) ->
    {Box, Close} = candid_wse:dock_pane(Ws, Title, right),
    Log = el(Ws, Box, "div", "flex:1;overflow:auto;padding:8px;"
	     "white-space:pre-wrap;word-break:break-word"),
    Foot = el(Ws, Box, "div", "display:flex;gap:6px;padding:6px 8px;"
	      "border-top:1px solid #333"),
    In = el(Ws, Foot, "textarea", "flex:1;height:4em;resize:vertical;"
	    "font:13px monospace;background:#111;color:#eee;"
	    "border:1px solid #555;padding:4px"),
    wse:set(Ws, In, "placeholder", "Enter sends, shift+Enter is a new line"),
    {ok, Send} = wse:create_event(Ws),
    %% Enter sends and clears; shift+Enter is a line break.
    wse:set(Ws, In, "onkeydown",
	    wse:newf(Ws, "e", "{ if (e && e.key == 'Enter' && !e.shiftKey) {"
		     " e.preventDefault(); Wse.notify(" ++ integer_to_list(Send) ++
		     ", this.value); this.value = ''; } }")),
    Busy = el(Ws, Foot, "span", "color:#fb3;align-self:center;min-width:2em"),
    Scroll = wse:newf(Ws, "e", "{ e.scrollTop = e.scrollHeight; }"),
    #{box => Box, log => Log, input => In, send => Send, close => Close,
      busy => Busy, scroll => Scroll}.

show(Ws, #{box := Box}, On) ->
    candid_wse:dock_show(Ws, Box, On).

%% What the person did: a line to send, or the pane closed.
event(#{send := Id}, {notify, Id, _, Text}) -> {send, Text};
event(#{close := Id}, {notify, Id, _, _})   -> close;
event(_P, _Msg)                             -> none.

el(Ws, Parent, Tag, Style) ->
    E = wse:createElement(Ws, Tag),
    wse:setStyle(Ws, E, Style),
    wse:appendChild(Ws, Parent, E),
    E.

say(Ws, #{log := Log, scroll := Scroll}, Who, Text) ->
    Style = case Who of
		user -> "color:#9cf;margin:10px 0 4px";
		assistant -> "color:#eee;margin:4px 0";
		note -> "color:#888;margin:0";
		error -> "color:#f66;margin:4px 0";
		console -> "color:#8d8;margin:0;white-space:pre"
	    end,
    D = el(Ws, Log, "div", Style),
    Prefix = case Who of user -> "> "; note -> "  · "; _ -> "" end,
    wse:appendChild(Ws, D, wse:createTextNode(
			     Ws, Prefix ++ unicode:characters_to_list(Text))),
    wse:cast(Ws, Scroll, "call", [null, Log]).

busy(Ws, #{busy := B}, On) ->
    wse:set(Ws, B, "textContent", candid_wse:u(case On of true -> "..."; false -> "" end)).

%%% The chat's pane for the browser, through wse: csp_chat converses, this
%%% shows it. Hung off document.body, not the panel's root, so a rebuild of
%%% the panel -- which `load' does -- leaves it standing.

-module(csp_chat_wse).

-export([pane/2, show/3, say/4, busy/3, event/2]).

-define(PANE, "position:fixed;top:0;right:0;bottom:0;width:38em;"
	"max-width:100vw;z-index:10;flex-direction:column;background:#1b1b1b;"
	"color:#ddd;border-left:1px solid #444;font:13px monospace;").

%% Hidden until show/3. Its events go to the process that makes it.
pane(Ws, Title) ->
    Box = wse:createElement(Ws, "div"),
    wse:setStyle(Ws, Box, ?PANE ++ "display:none"),
    Head = el(Ws, Box, "div", "display:flex;align-items:center;gap:8px;"
	      "padding:6px 8px;border-bottom:1px solid #333"),
    Title1 = el(Ws, Head, "span", "flex:1;color:#9cf"),
    wse:appendChild(Ws, Title1, wse:createTextNode(Ws, Title)),
    {ok, Close} = wse:create_event(Ws),
    X = el(Ws, Head, "button", "font:12px monospace"),
    wse:appendChild(Ws, X, wse:createTextNode(Ws, "close")),
    wse:set(Ws, X, "onclick", notify_f(Ws, Close, "'x'")),
    Log = el(Ws, Box, "div", "flex:1;overflow:auto;padding:8px;"
	     "white-space:pre-wrap;word-break:break-word"),
    Foot = el(Ws, Box, "div", "display:flex;gap:6px;padding:6px 8px;"
	      "border-top:1px solid #333"),
    In = el(Ws, Foot, "textarea", "flex:1;height:5em;resize:vertical;"
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
    Attach = wse:newf(Ws, "e", "{ document.body.appendChild(e); }"),
    wse:cast(Ws, Attach, "call", [null, Box]),
    Scroll = wse:newf(Ws, "e", "{ e.scrollTop = e.scrollHeight; }"),
    #{box => Box, log => Log, input => In, send => Send, close => Close,
      busy => Busy, scroll => Scroll}.

show(Ws, #{box := Box}, On) ->
    wse:setStyle(Ws, Box, ?PANE ++ case On of
				       true -> "display:flex";
				       false -> "display:none"
				   end).

%% What the person did: a line to send, or the pane closed.
event(#{send := Id}, {notify, Id, _, Text}) -> {send, Text};
event(#{close := Id}, {notify, Id, _, _})   -> close;
event(_P, _Msg)                             -> none.

el(Ws, Parent, Tag, Style) ->
    E = wse:createElement(Ws, Tag),
    wse:setStyle(Ws, E, Style),
    wse:appendChild(Ws, Parent, E),
    E.

notify_f(Ws, Id, Arg) ->
    wse:newf(Ws, "", "{ Wse.notify(" ++ integer_to_list(Id) ++ ", " ++ Arg ++
		 "); }").

say(Ws, #{log := Log, scroll := Scroll}, Who, Text) ->
    Style = case Who of
		user -> "color:#9cf;margin:10px 0 4px";
		assistant -> "color:#eee;margin:4px 0";
		note -> "color:#888;margin:0";
		error -> "color:#f66;margin:4px 0"
	    end,
    D = el(Ws, Log, "div", Style),
    Prefix = case Who of user -> "> "; note -> "  · "; _ -> "" end,
    wse:appendChild(Ws, D, wse:createTextNode(
			     Ws, Prefix ++ unicode:characters_to_list(Text))),
    wse:cast(Ws, Scroll, "call", [null, Log]).

busy(Ws, #{busy := B}, On) ->
    wse:set(Ws, B, "textContent", case On of true -> "..."; false -> "" end).

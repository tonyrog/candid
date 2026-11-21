%%% caned in a window of its own (wx): caned_ui's screen drawn as
%%% caned_ops' pixels, the keys caned_tty has and the mouse --
%%%
%%%   click        the cursor to a contact      double click   write it
%%%   drag         select the contacts in the rectangle (one rung's)
%%%   ^C ^X ^V     copy, cut, paste: the selection, or the contact under the
%%%                cursor; the system clipboard, candyspeak text
%%%   middle click paste X11's PRIMARY -- what was last selected, here or
%%%                anywhere -- onto the contact under the mouse
%%%   ^Z           undo (u), ^R redo
%%%   the number   a rung's handle: click selects the rule, double click
%%%                switches it off or on, drag puts it where it is let go
%%%   ⌥↑ ⌥↓        the rule or comment a line up, down
%%%   ⇧⏎ or ^J     writing a comment: a new line in it
%%%
%%% Its own window until it is candid's code view (the ops are csp_ladder's
%%% kind for that). One process owns the state; the paint callback reads the
%%% ops the last change made from an ets table.
%%%
%%%   ./caned -wx [-patch] FILE.csp

-module(caned_wx).

-export([main/1, start/1, start/2]).

-include_lib("wx/include/wx.hrl").

-define(FONT_PT, 11).
-define(DRAG, 4).                          % pixels before a press is a drag

main(["-patch", File]) -> main(File, patch);
main([File]) -> main(File, edit).

main(File, Access) ->
    case start(File, Access) of
	{ok, Pid} ->
	    Ref = monitor(process, Pid),
	    receive {'DOWN', Ref, _, _, _} -> halt(0) end;
	{error, {L, M}} ->
	    io:format(standard_error, "~s:~w: ~s~n", [File, L, M]),
	    halt(1)
    end.

%% {ok, Pid} | {error, {Line, Message}}: the window, its process Pid.
start(File) -> start(File, edit).

start(File, Access) ->
    case caned_ui:open(File, Access) of
	{ok, S} ->
	    Caller = self(),
	    Pid = spawn(fun() -> init(S, File, Caller) end),
	    receive {Pid, ready} -> {ok, Pid} end;
	E -> E
    end.

init(S, File, Caller) ->
    _ = wx:new(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, "caned -- " ++ filename:basename(File),
			[{size, {1000, 640}}]),
    Panel = wxPanel:new(Frame, [{style, ?wxWANTS_CHARS bor ?wxFULL_REPAINT_ON_RESIZE}]),
    Font = wxFont:new(?FONT_PT, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL,
		      ?wxFONTWEIGHT_NORMAL),
    Bold = wxFont:new(?FONT_PT, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL,
		      ?wxFONTWEIGHT_BOLD),
    wxWindow:setFont(Panel, Font),
    {Cw, Fh, _, _} = wxWindow:getTextExtent(Panel, "M"),
    M = #{cw => Cw, ch => Fh + 6, fh => Fh},
    Tab = ets:new(caned_wx, [public]),
    ets:insert(Tab, {ops, []}),
    wxWindow:connect(Panel, paint,
		     [{callback, fun(_, _) -> paint(Panel, Tab, M, Font, Bold) end}]),
    [wxWindow:connect(Panel, E) || E <- [char, left_down, left_up, left_dclick,
					 middle_down, motion, mousewheel, size]],
    wxFrame:connect(Frame, close_window),
    wxFrame:show(Frame),
    wxWindow:setFocus(Panel),
    Caller ! {self(), ready},
    W = #{frame => Frame, panel => Panel, tab => Tab, m => M, hits => [],
	  press => none, drag => none},
    loop(render(S, W)).

%%% ------------------------------------------------------------------ loop

loop({S, W = #{frame := Frame}}) ->
    receive
	#wx{event = #wxClose{}} ->
	    case caned_doc:dirty(maps:get(doc, S)) andalso not quit_anyway(Frame) of
		true -> loop({S, W});
		false -> wxFrame:destroy(Frame), wx:destroy()
	    end;
	#wx{event = #wxSize{}} -> loop(render(S, W));
	#wx{event = #wxKey{} = K} ->
	    case wx_key(K) of
		none -> loop({S, W});
		Key -> act(Key, S, W)
	    end;
	#wx{event = #wxMouse{} = Ev} -> mouse(Ev, S, W);
	_ -> loop({S, W})
    end.

act(Key, S, W) ->
    Key1 = case Key of
	       paste -> {paste, clipboard_text(S, false)};
	       _ -> Key
	   end,
    case caned_ui:key(Key1, S) of
	{ok, S1} -> loop(render(primary_out(clip_out(S1)), W));
	{quit, _} -> wxFrame:destroy(maps:get(frame, W)), wx:destroy()
    end.

%% What caned_ui left for the clipboard goes on the system's.
clip_out(S = #{clip := none}) -> S;
clip_out(S = #{clip := T}) ->
    put_text(T, false),
    S#{clip := none, last_clip => T}.

%% A new selection's text goes on X11's PRIMARY, for a middle click here or
%% in any other program.
primary_out(S) ->
    case {caned_ui:sel_text(S), maps:get(primary, S, none)} of
	{none, _} -> S;
	{T, T} -> S;
	{T, _} -> put_text(T, true), S#{primary => T}
    end.

put_text(T, Primary) ->
    CB = wxClipboard:get(),
    wxClipboard:usePrimarySelection(CB, [{primary, Primary}]),
    case wxClipboard:open(CB) of
	true ->
	    wxClipboard:setData(CB, wxTextDataObject:new([{text, T}])),
	    wxClipboard:close(CB);
	false -> ok
    end,
    wxClipboard:usePrimarySelection(CB, [{primary, false}]).

clipboard_text(S, Primary) ->
    CB = wxClipboard:get(),
    Own = case Primary of
	      true -> maps:get(primary, S, "");
	      false -> maps:get(last_clip, S, "")
	  end,
    wxClipboard:usePrimarySelection(CB, [{primary, Primary}]),
    T = case wxClipboard:open(CB) of
	    true ->
		D = wxTextDataObject:new(),
		X = case wxClipboard:getData(CB, D) of
			true -> wxTextDataObject:getText(D);
			false -> Own
		    end,
		wxClipboard:close(CB),
		wxTextDataObject:destroy(D),
		X;
	    false -> Own
	end,
    wxClipboard:usePrimarySelection(CB, [{primary, false}]),
    T.

quit_anyway(Frame) ->
    D = wxMessageDialog:new(Frame, "Not saved. Quit anyway?",
			    [{caption, "caned"}, {style, ?wxYES_NO bor ?wxNO_DEFAULT}]),
    R = wxMessageDialog:showModal(D),
    wxMessageDialog:destroy(D),
    R =:= ?wxID_YES.

%%% ----------------------------------------------------------------- mouse

mouse(#wxMouse{type = left_down, x = X, y = Y}, S, W) ->
    loop({S, W#{press := {X, Y}, drag := none}});
mouse(#wxMouse{type = motion, leftDown = true, x = X, y = Y}, S,
      W = #{press := {X0, Y0}}) when abs(X - X0) > ?DRAG; abs(Y - Y0) > ?DRAG ->
    W1 = W#{drag := {X0, Y0, X, Y}},
    loop({S, overlay(W1)});
mouse(#wxMouse{type = left_up, x = X, y = Y}, S, W = #{press := P, drag := Dr, hits := Hs}) ->
    W1 = W#{press := none, drag := none},
    From = case Dr of
	       {X0, Y0, _, _} -> caned_ops:hit(Hs, X0, Y0);
	       none -> none
	   end,
    Key = case {P, Dr} of
	      %% from a handle: the rule to the rung it is let go on
	      {_, {_, _, _, _}} when element(2, From) =:= handle ->
		  case caned_ops:handle_at(Hs, Y) of
		      none -> none;
		      To -> {move, element(1, From), To}
		  end;
	      {_, {_, _, _, _}} ->
		  case caned_ops:hits_in(Hs, Dr) of
		      {Ln, Ps} -> {select, Ln, Ps};
		      none -> none
		  end;
	      {{_, _}, none} ->
		  case caned_ops:hit(Hs, X, Y) of
		      {Ln, Pa} -> {click, Ln, Pa};
		      none -> none
		  end;
	      _ -> none
	  end,
    case Key of
	none -> loop(render(S, W1));
	_ -> act(Key, S, W1)
    end;
mouse(#wxMouse{type = mousewheel, wheelRotation = R}, S, W) ->
    act({scroll, -sign(R)}, S, W);
mouse(#wxMouse{type = middle_down, x = X, y = Y}, S, W = #{hits := Hs}) ->
    case caned_ops:hit(Hs, X, Y) of
	{Ln, Pa} ->
	    Text = clipboard_text(S, true),
	    {ok, S1} = caned_ui:key({click, Ln, Pa}, S),
	    act({paste, Text}, S1, W);
	none -> loop({S, W})
    end;
mouse(#wxMouse{type = left_dclick, x = X, y = Y}, S, W = #{hits := Hs}) ->
    case caned_ops:hit(Hs, X, Y) of
	{Ln, Pa} -> act({dclick, Ln, Pa}, S, W#{press := none});
	none -> loop({S, W})
    end;
mouse(_, S, W) -> loop({S, W}).

sign(R) when R > 0 -> 1;
sign(R) when R < 0 -> -1;
sign(_) -> 0.

%%% ------------------------------------------------------------------ keys

%% In a char event Ctrl + a letter comes as its control code, 1..26 (^C is
%% 3); some ports give the letter. Both are taken. AltGr arrives as Ctrl +
%% Alt on GTK -- `|' on a Swedish keyboard is AltGr + < -- so that is a
%% character, not a command.
wx_key(#wxKey{keyCode = C0, controlDown = true, altDown = Alt}) when Alt =/= true ->
    C = if C0 >= 1, C0 =< 26 -> C0 + $@;
	   C0 >= $a, C0 =< $z -> C0 - 32;
	   true -> C0
	end,
    case C of
	$C -> copy;
	$J -> newline;
	$X -> cut;
	$V -> paste;
	$Z -> $u;
	$R -> 18;
	$S -> $s;
	_ -> none
    end;
wx_key(#wxKey{keyCode = ?WXK_RETURN, shiftDown = true}) -> newline;
wx_key(#wxKey{keyCode = ?WXK_UP, altDown = true}) -> alt_up;
wx_key(#wxKey{keyCode = ?WXK_DOWN, altDown = true}) -> alt_down;
wx_key(#wxKey{keyCode = ?WXK_TAB, shiftDown = true}) -> shift_tab;
wx_key(#wxKey{keyCode = ?WXK_LEFT, shiftDown = true}) -> shift_left;
wx_key(#wxKey{keyCode = ?WXK_RIGHT, shiftDown = true}) -> shift_right;
wx_key(#wxKey{keyCode = C, uniChar = U}) ->
    case C of
	?WXK_LEFT -> left;
	?WXK_RIGHT -> right;
	?WXK_UP -> up;
	?WXK_DOWN -> down;
	?WXK_RETURN -> enter;
	?WXK_NUMPAD_ENTER -> enter;
	?WXK_ESCAPE -> esc;
	?WXK_BACK -> backspace;
	?WXK_DELETE -> del;
	?WXK_TAB -> tab;
	?WXK_PAGEUP -> page_up;
	?WXK_PAGEDOWN -> page_down;
	_ when is_integer(U), U >= $\s -> U;
	_ -> none
    end.

%%% ----------------------------------------------------------------- paint

%% The screen for the window's size, as ops for the paint callback.
render(S, W = #{panel := Panel, tab := Tab, m := M = #{cw := Cw, ch := Ch}}) ->
    {Wp, Hp} = wxWindow:getClientSize(Panel),
    {S1, Rows} = caned_ui:screen(S, max(3, Hp div Ch), max(20, Wp div Cw)),
    {Ops, Hits} = caned_ops:ops(Rows, M),
    ets:insert(Tab, {ops, Ops}),
    wxWindow:refresh(Panel, [{eraseBackground, false}]),
    {S1, W#{hits := Hits, base => Ops}}.

%% The rectangle being dragged, over the last screen.
overlay(W = #{panel := Panel, tab := Tab, base := Ops, drag := {X0, Y0, X1, Y1}}) ->
    R = {rect, min(X0, X1), min(Y0, Y1), abs(X1 - X0), abs(Y1 - Y0), 0, none,
	 {68, 170, 255}, true},
    ets:insert(Tab, {ops, Ops ++ [R]}),
    wxWindow:refresh(Panel, [{eraseBackground, false}]),
    W.

paint(Panel, Tab, #{fh := Fh, ch := Ch}, Font, Bold) ->
    DC = wxBufferedPaintDC:new(Panel),
    [{ops, Ops}] = ets:lookup(Tab, ops),
    wxDC:setFont(DC, Font),
    Ty = (Ch - Fh) div 2,
    Tools = lists:foldl(fun(Op, T) -> op(DC, Op, T, Ty, Font, Bold) end, #{}, Ops),
    [case K of
	 {pen, _, _, _} -> wxPen:destroy(X);
	 {brush, _} -> wxBrush:destroy(X)
     end || {K, X} <- maps:to_list(Tools)],
    wxBufferedPaintDC:destroy(DC).

op(DC, {rect, X, Y, W, H, R, F, St, Dash}, T0, _Ty, _F, _B) ->
    {Br, T1} = brush(F, T0),
    {Pen, T2} = pen(St, 1, Dash, T1),
    wxDC:setBrush(DC, Br),
    wxDC:setPen(DC, Pen),
    wxDC:drawRoundedRectangle(DC, {X, Y, W, H}, R),
    T2;
op(DC, {line, X1, Y1, X2, Y2, C, W, Dash}, T0, _Ty, _F, _B) ->
    {Pen, T1} = pen(C, W, Dash, T0),
    wxDC:setPen(DC, Pen),
    wxDC:drawLine(DC, {X1, Y1}, {X2, Y2}),
    T1;
op(DC, {text, X, Y, Txt, C, Bold}, T, Ty, Font, BoldF) ->
    Bold andalso wxDC:setFont(DC, BoldF),
    wxDC:setTextForeground(DC, C),
    wxDC:drawText(DC, Txt, {X, Y + Ty}),
    Bold andalso wxDC:setFont(DC, Font),
    T.

brush(none, T) -> tool({brush, none}, T, fun() -> ?wxTRANSPARENT_BRUSH end);
brush(C, T) -> tool({brush, C}, T, fun() -> wxBrush:new(C) end).

pen(none, _W, _D, T) -> tool({pen, none, 0, false}, T, fun() -> ?wxTRANSPARENT_PEN end);
pen(C, W, D, T) ->
    tool({pen, C, W, D}, T,
	 fun() -> wxPen:new(C, [{width, W},
				{style, case D of true -> ?wxDOT; false -> ?wxSOLID end}])
	 end).

%% One of each, kept for the paint; the stock ones are not destroyed.
tool(K, T, New) ->
    case maps:find(K, T) of
	{ok, X} -> {X, T};
	error ->
	    X = New(),
	    case K of
		{brush, none} -> {X, T};
		{pen, none, _, _} -> {X, T};
		_ -> {X, T#{K => X}}
	    end
    end.

%%% A program as candid holds it: what the panel, the code view, the prover
%%% and the chat work on. A sketch -- see MODES.md -- not yet what candid runs
%%% on; candid still holds a path.
%%%
%%% A FILE is its text LINE BY LINE, each line carrying what is done to it:
%%%
%%%   #{text, off, added}
%%%
%%%   off    the rule on the line is switched off (#disable). It is the
%%%          LINE that is off, not a number: a rule's number is worked out
%%%          when it is needed (numbers/1), as csp numbers them, so lines put
%%%          in above it renumber it and the mark stays where it was.
%%%   added  put in on a node that is running (patch mode), not in its image
%%%
%%% and around the lines:
%%%
%%%   name     none, or the path it is saved at. A file from a node has none
%%%            until one is bound to it.
%%%   origin   new | {disk, Path} | {node, Device}
%%%   mode     edit -- anything may change, the chat included -- or patch:
%%%            only lines added at the end and rules turned off and on, as on
%%%            a node that is running. A file from a node is in patch mode.
%%%   image    none, or the image a node's file was listed from: its header
%%%            CRC, which names the image (a stored patch carries it as
%%%            rom_fp), and the CRC of the patch on it. Loading again from the
%%%            same node can then tell whether it already has that program.
%%%
%%% What changes a file returns what to send to the node it is live on, csp
%%% lines, empty when it is not live: {ok, F, Send}.
%%%
%%% On disk the marks are `#disable N' lines at the end, as csp reads them;
%%% load/1 takes them off and puts the marks back on their lines.
%%%
%%% A WORKSPACE is the files open, one of them active: a tab each. A device
%%% has one tab: a file from a node replaces the one from the same device.
%%%
%%% Traces and assignments are to hang off a file too (MODES.md); not yet.

-module(candid_file).

-export([new/0, load/1, from_node/3, save/2, write/2]).
-export([edit/2, add/2, disable/2, enable/2]).
-export([text/1, source/1, numbers/1, rules/1, label/1, live/1,
	 same_image/2, image_id/1]).
-export([workspace/0, open/2, close/2, activate/2, active/1, files/1,
	 update/2]).

-define(HEADER_DATA_LEN, (11 * 2 + 7 * 4)).   % csp_disasm's

%%% ------------------------------------------------------------- one file

new() ->
    #{id => erlang:unique_integer([positive]), name => none, origin => new,
      mode => edit, lines => [], image => none, dirty => false}.

%% A program on disk, named by where it is. Its `#disable' lines become the
%% marks on the lines they name.
load({disk, Path}) ->
    case file:read_file(Path) of
	{ok, Bin} ->
	    {Ls, Offs} = marks(lines(binary_to_list(Bin))),
	    F = (new())#{name => Path, origin => {disk, Path}, lines => Ls},
	    mark_off(F, Offs);
	{error, Why} ->
	    {error, {Path, Why}}
    end.

%% The program a node runs, as csp_link lists it off the node's image (Text)
%% and the image and patch it read (Dumps, csp_node:dumps/1's form).
from_node(Device, Text, Dumps) ->
    (new())#{origin => {node, Device}, mode => patch, lines => lines(Text),
	     image => image_of(Dumps)}.

%% Saved at Path, which is its name from then on, and where it comes from --
%% unless it is a node's: that one keeps coming from the node, still patched
%% there, with a name besides.
save(F, Path) ->
    case write(F, Path) of
	ok -> {ok, F#{name := Path, dirty := false,
		      origin := case F of
				    #{origin := {node, _} = O} -> O;
				    _ -> {disk, Path}
				end}};
	Error -> Error
    end.

%% Its text written at Path, the file as it was: a copy to run.
write(F, Path) ->
    case text(F) of
	{ok, T} ->
	    case file:write_file(Path, bytes(T)) of
		ok -> ok;
		{error, Why} -> {error, {Path, Why}}
	    end;
	Error -> Error
    end.

%% The text is kept as the scanner reads a file, a byte a character, so a
%% file in Latin-1 is written back as it was; what the chat put in past
%% Latin-1 goes out as UTF-8.
bytes(T) ->
    try list_to_binary(T)
    catch error:badarg -> unicode:characters_to_binary(T)
    end.

%% The text replaced, as an editor or the chat would. A mark stays on its
%% line where the line is still there: the Kth line reading T is the Kth
%% reading T after it.
%%
%% In patch mode the text may only grow at the end, the lines before it as
%% they were; what is new is sent.
edit(F = #{mode := edit, lines := Ls}, Text) ->
    Offs = [Key || {Key, #{off := true}} <- keyed(Ls)],
    New = [case lists:member(Key, Offs) of
	       true  -> L#{off := true};
	       false -> L
	   end || {Key, L} <- keyed(lines(Text))],
    {ok, F#{lines := New, dirty := true}, []};
edit(F = #{mode := patch, lines := Ls}, Text) ->
    Old = drop_blank(Ls),
    New = lines(Text),
    case lists:prefix(texts(Old), texts(New)) of
	true ->
	    Tail = lists:nthtail(length(Old), New),
	    {ok, F#{lines := Old ++ [L#{added := true} || L <- Tail],
		    dirty := true},
	     send(F, [T || #{text := T} <- Tail, string:trim(T) =/= ""])};
	false ->
	    {error, patch_mode}
    end.

%% A line put in at the end: in either mode.
add(F = #{lines := Ls}, Text) ->
    Tail = [L#{added := true} || L <- lines(Text)],
    {ok, F#{lines := drop_blank(Ls) ++ Tail, dirty := true},
     send(F, [T || #{text := T} <- Tail])}.

%% Rule No switched off, or on: the mark goes on the line it is on now.
disable(F, No) -> switch(F, No, true).
enable(F, No)  -> switch(F, No, false).

switch(F = #{lines := Ls}, No, Off) ->
    case numbers(F) of
	{ok, Nos} ->
	    case [Ix || {Ix, N} <- Nos, N =:= No] of
		[Ix | _] ->
		    Ls1 = set_nth(Ix, Ls, fun(L) -> L#{off := Off} end),
		    Cmd = case Off of true -> "#disable "; false -> "#enable " end,
		    {ok, F#{lines := Ls1, dirty := true},
		     send(F, [Cmd ++ integer_to_list(No)])};
		[] ->
		    {error, {no_such_rule, No}}
	    end;
	Error -> Error
    end.

send(#{origin := {node, _}}, Lines) -> Lines;
send(_F, _Lines) -> [].

%% What the file says, as csp reads it: its lines, then the rules that are
%% off as one `#disable' line.
text(F = #{lines := Ls}) ->
    case lists:any(fun(#{off := O}) -> O end, Ls) of
	false -> {ok, source(F)};
	true ->
	    case numbers(F) of
		{ok, Nos} ->
		    Off = [integer_to_list(N)
			   || {Ix, N} <- Nos,
			      maps:get(off, lists:nth(Ix, Ls))],
		    {ok, lists:flatten([source(F), "#disable ",
					lists:join(" ", Off), "\n"])};
		Error -> Error
	    end
    end.

%% The lines alone, as an editor shows them.
source(#{lines := Ls}) ->
    lists:flatten([[T, $\n] || #{text := T} <- Ls]).

%% The rules' numbers, as csp numbers them: [{LineNo, RuleNo}], one per rule,
%% LineNo counting from 1 in this file. The file is parsed as if it were at
%% its name -- or in the current directory -- so its #imports, whose rules
%% are numbered too, are found from there.
numbers(F) ->
    Top = top(F),
    case quiet(fun() -> candyspeak:parse_text(source(F), Top, [sources]) end) of
	{ok, Ast} ->
	    Base = filename:basename(Top),
	    {ok, [{Ln, No} || #{no := No, line := Ln, file := File}
				  <- csp_code:rules(Ast, Top),
			      File =:= Base]};
	_Error ->
	    {error, not_parsed}
    end.

top(#{name := none}) -> filename:absname("untitled.csp");
top(#{name := Path}) -> Path.

%% The rules as the view and the chat list them: [{No, LineNo, Text, Off}].
rules(F = #{lines := Ls}) ->
    case numbers(F) of
	{ok, Nos} ->
	    {ok, [{No, Ix, T, Off} || {Ix, No} <- Nos,
				      #{text := T, off := Off}
					  <- [lists:nth(Ix, Ls)]]};
	Error -> Error
    end.

%% A tab's name: the file's own, or the device it came from; `*' when it has
%% changed since it was loaded or saved.
label(F = #{dirty := D}) ->
    Base = case F of
	       #{name := none, origin := {node, Dev}} -> Dev;
	       #{name := none} -> "new";
	       #{name := Path} -> filename:basename(Path)
	   end,
    case D of
	true  -> Base ++ " *";
	false -> Base
    end.

live(#{origin := {node, _}}) -> true;
live(_) -> false.

%% Whether Dumps, read off a node again, are the program this file already
%% holds: the same image with the same patch.
same_image(#{image := none}, _Dumps) -> false;
same_image(#{image := I}, Dumps) -> image_of(Dumps) =:= I.

image_of(Dumps) ->
    case [B || {rom, B} <- Dumps] of
	[Rom | _] ->
	    #{rom => image_id(Rom),
	      patch => case [B || {K, B} <- Dumps, K =:= patch orelse
				      K =:= eeprom] of
			   [P | _] -> erlang:crc32(P);
			   []      -> none
		       end};
	[] -> none
    end.

%% An image's name: the CRC of its header, as it is stored, so either byte
%% order compares to itself.
image_id(<<"JAM\n", _:?HEADER_DATA_LEN/binary, Crc:2/binary, _/binary>>) ->
    Crc;
image_id(_) ->
    none.

%%% ---------------------------------------------------------------- lines

lines(Text) ->
    Ts = string:split(Text, "\n", all),
    Ts1 = case lists:last(Ts) of
	      "" -> lists:droplast(Ts);
	      _  -> Ts
	  end,
    [#{text => T, off => false, added => false} || T <- Ts1].

texts(Ls) -> [T || #{text := T} <- Ls].

drop_blank(Ls) ->
    lists:reverse(lists:dropwhile(fun(#{text := T}) -> string:trim(T) =:= "" end,
				  lists:reverse(Ls))).

%% Each line with the key a mark follows it by: its text, and how many lines
%% above read the same.
keyed(Ls) -> keyed(Ls, #{}).

keyed([L = #{text := T} | Ls], Seen) ->
    K = maps:get(T, Seen, 0),
    [{{T, K}, L} | keyed(Ls, Seen#{T => K + 1})];
keyed([], _Seen) -> [].

set_nth(1, [X | T], Fun) -> [Fun(X) | T];
set_nth(N, [X | T], Fun) -> [X | set_nth(N - 1, T, Fun)].

%% The `#disable'/`#enable' lines taken out, and the rules they leave off,
%% in order: a later #enable undoes an earlier #disable.
marks(Ls) -> marks(Ls, [], []).

marks([L = #{text := T} | Ls], Acc, Offs) ->
    case string:lexemes(T, " \t") of
	["#disable" | Ns] -> marks(Ls, Acc, Offs ++ [N || N <- nos(Ns)]);
	["#enable" | Ns]  -> marks(Ls, Acc, Offs -- nos(Ns));
	_                 -> marks(Ls, [L | Acc], Offs)
    end;
marks([], Acc, Offs) -> {lists:reverse(Acc), lists:usort(Offs)}.

nos(Ns) ->
    lists:append([case string:split(N, "-") of
		      [A, B] -> lists:seq(list_to_integer(A), list_to_integer(B));
		      [A]    -> [list_to_integer(A)]
		  end || N <- Ns, not lists:prefix("//", N)]).

mark_off(F, []) -> {ok, F};
mark_off(F = #{lines := Ls}, Offs) ->
    case numbers(F) of
	{ok, Nos} ->
	    Ixs = [Ix || {Ix, N} <- Nos, lists:member(N, Offs)],
	    {ok, F#{lines := [case lists:member(Ix, Ixs) of
				  true  -> L#{off := true};
				  false -> L
			      end || {Ix, L} <- lists:enumerate(Ls)]}};
	Error -> Error
    end.

%% The parser says what it cannot read on standard output.
quiet(Fun) ->
    {ok, Null} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Null, self()),
    try Fun() after group_leader(Old, self()), file:close(Null) end.

%%% ------------------------------------------------------------ workspace

workspace() -> #{files => [], active => none}.

%% F open and active. A node's file replaces the one from the same device:
%% a device has one tab. A file from disk opened again replaces itself.
open(W = #{files := Fs}, F) ->
    Fs1 = case F of
	      #{origin := new} -> Fs;
	      #{origin := O} -> [G || G <- Fs, maps:get(origin, G) =/= O]
	  end,
    W#{files := Fs1 ++ [F], active := maps:get(id, F)}.

%% Closed; the one before it is active if it was.
close(W = #{files := Fs, active := A}, Id) ->
    {Before, After} = lists:splitwith(fun(#{id := I}) -> I =/= Id end, Fs),
    Fs1 = Before ++ tl_or_nil(After),
    A1 = case {A, Before, Fs1} of
	     {Id, [_ | _], _} -> maps:get(id, lists:last(Before));
	     {Id, [], [G | _]} -> maps:get(id, G);
	     {Id, [], []} -> none;
	     _ -> A
	 end,
    W#{files := Fs1, active := A1}.

tl_or_nil([_ | T]) -> T;
tl_or_nil([]) -> [].

activate(W = #{files := Fs}, Id) ->
    case lists:any(fun(#{id := I}) -> I =:= Id end, Fs) of
	true  -> {ok, W#{active := Id}};
	false -> {error, no_such_file}
    end.

active(#{active := none}) -> none;
active(#{files := Fs, active := A}) ->
    hd([F || F = #{id := I} <- Fs, I =:= A]).

files(#{files := Fs}) -> Fs.

%% A file changed (patched, saved, edited) put back in its place.
update(W = #{files := Fs}, F = #{id := Id}) ->
    W#{files := [case G of #{id := Id} -> F; _ -> G end || G <- Fs]}.

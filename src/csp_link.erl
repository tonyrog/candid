%%% Drives one csp process as an Erlang port.
%%%
%%% The owner receives {csp_state, Cycle, [{Name,Value}]} for every state dump
%%% csp prints, and {csp_fired, Cycle, [{Object, File, Line}]} whenever the set
%%% of rules that fired changes (--fired; the code view lights them), and
%%% {csp_clock, Cycle, Ms} every cycle, Ms being the program's own clock since
%%% start. Note that csp dumps ON CHANGE, not every cycle, so a trace must
%%% hold its last value between dumps rather than expect one per tick.
%%%
%%% A NODE can be the other end instead: its console on tcp or a serial line
%%% (target/1). It has no -Q stream, so a tick asks: /dump state, read against
%%% the program /dump rom and /dump eeprom said it runs. The same messages come
%%% back, without csp_fired, and the node is never sent /quit -- closing just
%%% lets go of it. The owner also gets {csp_link, Text}, what is connected,
%%% {csp_out, Line} for the rest of what a local csp prints,
%%% and {csp_program, Text, Dumps}: the node's program as source, listed off
%%% its image and patch by csp_list -- what it runs, whatever file the panel
%%% had open -- and the dumps it was listed from, [{rom, Bin} | {patch |
%%% eeprom, Bin}], which name that image (candid_file:same_image/2).
%%%
%%% Ticking is ours to drive. A csp of our own is paused from the start and
%%% never resumed: left running it takes a cycle of its own every time its
%%% loop wakes -- every 100 ms, and on every line we send -- so a /commit a
%%% tick made two cycles a tick, and a value set from a widget a third. Paused,
%%% a tick is /step 1: exactly one cycle, which reads the values set since
%%% the last one, as a board does. Not /commit first: committing while paused
%%% makes the new value the previous one as well, and an edge (falling(K))
%%% is never seen -- the lock took no keys.

-module(csp_link).

-export([open/2, open/3, close/1, set/3, tick/1, raw/2]).
-export([pause/1, resume/1, step/1, step/2, reset/1, clock/2]).
-export([init/4]).

open(Exe, Files) -> open({{local, "vcan0"}, #{patch => none, image => none}},
			 Exe, Files).

open(Target, Exe, Files) ->
    Owner = self(),
    {ok, spawn_link(?MODULE, init, [Owner, Target, Exe, Files])}.

%% Where to: csp_cmd:target/1 reads the panel's target field. A csp of our
%% own ({local, If}) is run here as a port; a node's console is connected by
%% csp_cmd, and read here a message at a time.

close(L)          -> L ! close, ok.
set(L, Name, Val) -> L ! {set, Name, Val}, ok.
%% A line typed by the person, sent as it is. What comes back is {csp_out,
%% Line} as anything else csp prints; a node's console, which is otherwise
%% only read for dumps, is passed on for a while after it.
raw(L, Line)      -> L ! {raw, Line}, ok.
tick(L)           -> L ! tick, ok.

%% Stepping, which is not the same as ticking.
%%
%% Our own csp: `tick' is a step, and pause / resume only stop and start the
%% panel's ticks (the module doc). A NODE runs on its own: pause and resume
%% are /pause and /resume there, and a tick only asks for its state.
%%
%% Paused, values are set without running anything, and /step N runs exactly
%% N cycles and stops again. That is the sequence that behaves like hardware,
%% where every DIN is committed at the top of one cycle, and it is what a
%% replayed model trace needs to match its source.
%%
%% A value set while paused is read by the next step's rules, the inputs of
%% step t in step t, as a replayed model trace needs. Our own csp is sent no
%% /commit before the step: it would make the value the previous one too,
%% and no edge would be seen (measured on lock.csp: falling(K1) never fired).
pause(L)          -> L ! pause, ok.
resume(L)         -> L ! resume, ok.
step(L)           -> step(L, 1).
step(L, N)        -> L ! {step, N}, ok.
%% Back to the initial values, State INIT, cycle 0. Prints no dump: the next
%% step's dump says what differs from the last one printed.
reset(L)          -> L ! reset, ok.
clock(L, Ms)      -> L ! {clock, Ms}, ok.

init(Owner, {{local, Can}, #{patch := Patch}}, Exe, Files) ->
    %% Trap exits so the owner dying becomes a MESSAGE rather than killing us
    %% outright. Without this the panel's death takes this process with it
    %% before it can send /quit, the port closes, and csp -- whose own help
    %% says EOF ends the prompt and not the program -- runs on forever.
    process_flag(trap_exit, true),
    link(Owner),
    %% NO --virtual-time. It jumps the clock to the next timer deadline, so a
    %% 500 ms phase fires on every tick and traffic.csp runs four times too
    %% fast (measured: 202 ms between phases against 1161 in real time). The
    %% panel wants wall time -- watching it is the point -- and real time is
    %% what csp does when the flag is absent.
    %%
    %% --exit-on-eof: when our end of the pipe goes, so should csp.
    %%
    %% NO -b, though it would be the right thing. Starting paused would give the
    %% trace a known zero point -- without it csp runs INIT and whatever cycles
    %% fit before the first dump, so a step starts from wherever the scheduler
    %% was. But `-b -Q' produces NO DUMPS AT ALL (measured: 0 against 3), and
    %% the dump stream is the panel's only way of seeing anything. Put the -b
    %% back when that combination works.
    Port = open_port({spawn_executable, Exe},
		     [{args, ["-i"] ++ [A || Patch =/= stored, A <- ["--no-eeprom"]] ++
			     ["-Q", "-Lerlang", "--delta",
			      "--fired",
			      "--can=" ++ Can, "--exit-on-eof" | Files]},
		      exit_status, use_stdio, stderr_to_stdout,
		      {line, 4096}]),
    cmd(Port, "/pause\n"),
    Owner ! {csp_link, "local csp on " ++ Can ++
		 case Patch of stored -> ", eeprom patch"; _ -> "" end},
    loop(#{port => Port, owner => Owner, buf => [], run => true,
	   pending => []});
init(Owner, T = {Target, Opts}, _Exe, _Files) ->
    process_flag(trap_exit, true),
    link(Owner),
    case csp_cmd:open(T) of
	{ok, C} ->
	    Owner ! {csp_link, "reading the program from " ++ csp_cmd:where(Target)},
	    %% what the node is, first: a node from before /dump info refuses
	    %% it, and the program is read all the same
	    csp_cmd:send(C, "/dump info"),
	    remote(Owner, #{conn => C, target => Target, opts => Opts,
			    want => info, buf => none, rom => none,
			    decls => none, asked => none, cycle => 0,
			    until => 0});
	{error, Why} ->
	    Owner ! {csp_link, io_lib:format("~s: ~p",
					     [csp_cmd:where(Target), Why])},
	    Owner ! {csp_exit, Why}
    end.

%% run: the panel is ticking (go) rather than stepping by hand. pending: the
%% names set since the last cycle. While running, a name set a second time
%% before the tick gets a cycle of its own first: a click, pressed and let go
%% inside one tick, would otherwise be one value and no edge.
loop(S = #{port := Port, owner := Owner, buf := Buf, run := Run,
	   pending := Pending}) ->
    receive
	{Port, {data, {eol, Line}}} ->
	    loop(S#{buf := feed(Owner, Buf, Line)});
	{Port, {data, {noeol, Line}}} ->
	    loop(S#{buf := feed(Owner, Buf, Line)});
	{Port, {exit_status, St}} ->
	    Owner ! {csp_exit, St};
	{set, Name, Val} ->
	    P = case Run andalso lists:member(Name, Pending) of
		    true -> cmd(Port, "/step 1\n"), [];
		    false -> Pending
		end,
	    cmd(Port, ["> ", Name, " = ", fmt(Val), "\n"]),
	    loop(S#{pending := [Name | P]});
	{raw, Line} ->
	    cmd(Port, [Line, "\n"]),
	    loop(S);
	tick ->
	    cmd(Port, "/step 1\n"),
	    loop(S#{pending := []});
	%% Paused already, and stays so: run is the panel ticking.
	pause ->
	    loop(S#{run := false});
	resume ->
	    loop(S#{run := true});
	{step, N} ->
	    cmd(Port, ["/step ", integer_to_list(N), "\n"]),
	    loop(S#{pending := []});
	reset ->
	    cmd(Port, "/reset\n"),
	    loop(S#{pending := []});
	{clock, Ms} ->
	    cmd(Port, ["/clock ", integer_to_list(Ms), "\n"]),
	    loop(S);
	close ->
	    shutdown(Port);
	%% The panel went away: browser closed, or it crashed. Same handling --
	%% we are the only one holding this csp, so it is ours to end.
	{'EXIT', Owner, _Reason} ->
	    shutdown(Port);
	{'EXIT', _Other, _Reason} ->
	    loop(S)
    end.

%% A line to our csp. Gone already -- it exited, and its exit_status is
%% still in the queue behind what is handled now -- the line goes nowhere:
%% the exit is told when its message is read, not by a crash here.
cmd(Port, Data) ->
    try port_command(Port, Data) catch error:badarg -> ok end.

%% /quit makes csp exit at once (measured: 0 ms), so wait for that rather than
%% just closing the port. Closing alone leaves it running, and walking away
%% without sending anything is what left processes behind.
shutdown(Port) ->
    cmd(Port, "/quit\n"),
    receive
	{Port, {exit_status, _}} -> ok
    after 500 ->
	    %% /quit did not take. Close the pipe and make sure of the process;
	    %% by here it is either wedged or ignoring us.
	    OsPid = case erlang:port_info(Port, os_pid) of
			{os_pid, Pid} -> Pid;
			undefined     -> undefined
		    end,
	    try port_close(Port) catch _:_ -> ok end,
	    kill(OsPid)
    end.

%%% ------------------------------------------------------------------ a node

send(#{conn := C}, Line) -> csp_cmd:send(C, Line).

remote(Owner, St = #{conn := C}) ->
    receive
	{raw, Line} ->
	    send(St, Line),
	    remote(Owner, St#{echo => erlang:monotonic_time(millisecond) + 2000});
	{set, Name, Val} ->
	    send(St, ["> ", Name, " = ", fmt(Val)]),
	    remote(Owner, St);
	tick ->
	    remote(Owner, ask(St));
	pause ->
	    send(St, "/pause"),
	    remote(Owner, St);
	resume ->
	    send(St, "/resume"),
	    remote(Owner, St);
	%% A node steps in its own loop, after the command line is read, so a
	%% /dump state right behind /step can land between steps. Ask until the
	%% cycle has got there.
	{step, N} ->
	    send(St, "/commit"),
	    send(St, "/step " ++ integer_to_list(N)),
	    #{cycle := Cy} = St,
	    remote(Owner, ask(St#{asked := none, until := Cy + N}));
	again ->
	    remote(Owner, ask(St));
	reset ->
	    send(St, "/reset"),
	    remote(Owner, ask(St#{asked := none, until := 0}));
	{clock, Ms} ->
	    send(St, "/clock " ++ integer_to_list(Ms)),
	    remote(Owner, St);
	close ->
	    csp_cmd:close(C);
	{'EXIT', Owner, _} ->
	    csp_cmd:close(C);
	{'EXIT', _, _} ->
	    remote(Owner, St);
	Msg ->
	    case csp_cmd:msg(C, Msg) of
		{lines, Ls, C1} ->
		    remote(Owner, lists:foldl(fun(L, Si) -> line(Owner, L, Si) end,
					      St#{conn := C1}, Ls));
		{closed, Why} -> gone(Owner, Why);
		no -> remote(Owner, St)
	    end
    end.

gone(Owner, Why) ->
    Owner ! {csp_link, io_lib:format("node gone: ~p", [Why])},
    Owner ! {csp_exit, Why}.

%% One /dump state in flight at a time: a tick faster than the line is slower
%% than the reply would otherwise queue up requests without end. One that got
%% lost is given up after a second.
ask(St = #{decls := Ds, asked := T}) when Ds =/= none ->
    Now = erlang:monotonic_time(millisecond),
    case T =:= none orelse Now - T > 1000 of
	true  -> send(St, "/dump state"), St#{asked := Now};
	false -> St
    end;
ask(St) ->
    St.

%% The console echoes and prompts as well; only the replies are read. A dump
%% is its head line, hex lines and a `.'.
line(Owner, L0, St = #{buf := none}) ->
    case L0 of
	L = "dump " ++ _ -> St#{buf := [L]};
	L = "ERR " ++ _  -> refused(Owner, L, St);
	L ->
	    %% monotonic time is often below 0: no `echo' is not a 0
	    case maps:get(echo, St, none) of
		Until when is_integer(Until) ->
		    erlang:monotonic_time(millisecond) < Until
			andalso said(Owner, L);
		none -> ok
	    end,
	    St
    end;
line(Owner, L0, St = #{buf := Buf}) ->
    case L0 of
	"." ->
	    Text = lists:join("\n", lists:reverse(Buf, ["."])),
	    reply(Owner, csp_node:dumps(lists:flatten(Text)),
		  St#{buf := none});
	L -> St#{buf := [L | Buf]}
    end.

%% A line that came wrong, or never came: asked for again by its offset, one
%% window at a time, until the whole is there. A few tries, then said.
reply(Owner, [{part, K, P}], St = #{want := W})
  when K =:= W; W =:= patch, K =:= eeprom ->
    Tries = maps:get(tries, St, 0),
    case csp_node:merge(maps:get(piece, St, P#{have := []}), {part, K, P}) of
	{K, Bin} ->
	    reply(Owner, [{K, Bin}], maps:without([piece, tries], St));
	{part, K, P1 = #{want := [{O, L} | _]}} when Tries < 5 ->
	    send(St, [dump_cmd(K, St), " ", integer_to_list(O), " ",
		      integer_to_list(L)]),
	    St#{piece => P1, tries => Tries + 1};
	_ ->
	    Owner ! {csp_link, io_lib:format("~s did not come whole", [K])},
	    maps:without([piece, tries], St)
    end;
reply(Owner, [{info, Bin}], St = #{want := info, target := T}) ->
    try csp_node:info(Bin) of
	Info ->
	    Owner ! {csp_link, "node " ++ csp_cmd:where(T) ++ ": " ++
			 csp_cmd:info_text(Info)},
	    read_rom(St#{info => Info})
    catch
	_:Why ->
	    Owner ! {csp_link, io_lib:format("node info not read: ~P", [Why, 6])},
	    read_rom(St)
    end;
reply(Owner, [{rom, Bin}], St = #{want := rom, opts := #{patch := P}}) ->
    case P of
	none   -> program(Owner, [{rom, Bin}], St#{rom := Bin});
	live   -> send(St, "/dump patch");
	stored -> send(St, "/dump eeprom")
    end,
    St#{rom := Bin, want := patch};
reply(Owner, [{K, Bin}], St = #{want := patch, rom := Rom})
  when K =:= patch; K =:= eeprom ->
    program(Owner, [{rom, Rom}, {K, Bin}], St);
reply(Owner, [D = {state, Cycle, Ms, _, _}], St = #{decls := Ds})
  when Ds =/= none ->
    try csp_node:state(Ds, D) of
	Vals ->
	    Owner ! {csp_state, Cycle, lists:append([head(V) || V <- Vals])},
	    Owner ! {csp_clock, Cycle, Ms}
    catch
	_:Why ->
	    Owner ! {csp_link, io_lib:format("state not read: ~P", [Why, 6])}
    end,
    case St of
	#{until := U} when Cycle < U -> erlang:send_after(20, self(), again);
	_ -> ok
    end,
    St#{asked := none, cycle := Cycle};
%% Not understood (a node of another make): said, and while reading the
%% program it is given up rather than waited for.
reply(Owner, [{unknown, Head}], St = #{want := info}) ->
    Owner ! {csp_link, "node: a dump not understood: dump " ++ Head},
    read_rom(St);
reply(Owner, [{unknown, Head}], St = #{want := W}) ->
    Owner ! {csp_link, "node: a dump not understood: dump " ++ Head},
    case W of
	state -> St#{asked := none};
	_     -> St#{want := none}
    end;
reply(_Owner, _, St) ->
    St.

read_rom(St = #{opts := Opts}) ->
    send(St, case Opts of
		 #{image := none} -> "/dump rom";
		 #{image := I}    -> ["/dump rom ", I]
	     end),
    St#{want := rom}.

%% What reads K again, a window of it after.
dump_cmd(rom, #{opts := #{image := none}}) -> "/dump rom";
dump_cmd(rom, #{opts := #{image := I}}) -> ["/dump rom ", I];
dump_cmd(K, _St) -> ["/dump ", atom_to_list(K)].

%% Nothing stored is an image with no patch; anything else refused while
%% reading the program leaves nothing to read the state by.
refused(_Owner, _L, St = #{want := info}) ->
    read_rom(St);
refused(Owner, _L, St = #{want := patch, rom := Rom}) ->
    program(Owner, [{rom, Rom}], St);
refused(Owner, L, St = #{want := rom}) ->
    Owner ! {csp_link, "node: " ++ csp_cmd:reply(L)},
    St;
refused(_Owner, _L, St) ->
    St#{asked := none}.

program(Owner, Ds, St = #{target := T}) ->
    case silent(fun() -> try csp_node:program(Ds) catch C:W -> {C, W} end
		end) of
	{ok, P = {_, _, Decls, _}} ->
	    Owner ! {csp_link, io_lib:format("node ~s, ~w declarations~s",
					     [csp_cmd:where(T), length(Decls),
					      patched(Ds)])},
	    %% a transport the program names and the node lacks: it runs,
	    %% and that buffer never delivers
	    [Owner ! {csp_link, "node " ++ csp_cmd:where(T) ++ ": " ++ Tx ++
			  " (" ++ N ++ ") is the null device here -- never "
			  "delivers, " ++ N ++ ".rx stays false"}
	     || #{text := Tx, name := N}
		    <- csp_list:null(csp_list:uses(P), maps:get(info, St, #{}))],
	    %% what the node said of itself goes with its program
	    Info = [{info, I} || I <- [maps:get(info, St, none)], I =/= none],
	    case listing(Ds) of
		{ok, Text} -> Owner ! {csp_program, Text, Ds ++ Info};
		Error ->
		    Owner ! {csp_link, io_lib:format("node ~s: not listed: ~P",
						     [csp_cmd:where(T), Error, 8])}
	    end,
	    St#{decls := Decls, want := state};
	Other ->
	    Owner ! {csp_link, io_lib:format("node ~s: program not read: ~P",
					     [csp_cmd:where(T), Other, 8])},
	    St#{want := none}
    end.

listing([{rom, Rom}]) -> csp_list:image(Rom, #{source => true});
listing([{rom, Rom}, {_, Patch}]) -> csp_list:patch(Rom, Patch, #{source => true}).

patched([_, {patch, _}])  -> " + the patch running";
patched([_, {eeprom, _}]) -> " + the patch stored";
patched(_)                -> "".

%% The disassembler prints as it goes.
silent(F) ->
    {ok, Null} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Null, self()),
    try F() after group_leader(Old, self()), file:close(Null) end.

kill(undefined) -> ok;
kill(Pid)       -> os:cmd("kill -TERM " ++ integer_to_list(Pid)), ok.

fmt(V) when is_integer(V) -> integer_to_list(V);
fmt(V) when is_list(V)    -> V.

%%% A dump spans three lines -- "{state,N,[", the values, then "]}." -- and the
%%% prompt "> " may be prepended to any of them, sometimes twice.

feed(Owner, [], Line) ->
    case string:find(Line, "{state,") of
	nomatch ->
	    case one_line(Line, ["{fired,", "{clock,"]) of
		nomatch -> said(Owner, Line), [];
		F       -> emit(Owner, F), []
	    end;
	Rest -> hold(Owner, [Rest])
    end;
feed(Owner, Buf, Line) ->
    hold(Owner, [strip(Line) | Buf]).

%% Anything else csp prints goes to the owner as {csp_out, Line} -- an error
%% after a set, Paused -- but not its prompts, nor the /commit every tick and
%% its answer.
said(Owner, Line) ->
    case prompts(string:trim(Line)) of
	""          -> ok;
	"/commit"   -> ok;
	"Committed" -> ok;
	"/step 1"   -> ok;
	"/pause"    -> ok;
	"/dump state" -> ok;
	"Paused (" ++ _ -> ok;
	L           -> Owner ! {csp_out, L}
    end.

prompts("> " ++ L) -> prompts(string:trim(L, leading));
prompts(">") -> "";
prompts(L) -> L.

one_line(_Line, []) -> nomatch;
one_line(Line, [Tag | Tags]) ->
    case string:find(Line, Tag) of
	nomatch -> one_line(Line, Tags);
	F       -> F
    end.

hold(Owner, Buf = [Last | _]) ->
    case lists:suffix("]}.", Last) of
	true  -> emit(Owner, lists:flatten(lists:reverse(Buf))), [];
	false -> Buf
    end.

strip("> " ++ Rest) -> strip(Rest);
strip(Line)         -> Line.

emit(Owner, Text) ->
    case erl_scan:string(Text) of
	{ok, Toks, _} ->
	    case erl_parse:parse_term(Toks) of
		{ok, {state, N, Vals}} -> Owner ! {csp_state, N, flat(Vals)};
		{ok, {fired, N, Rs}}   -> Owner ! {csp_fired, N, Rs};
		{ok, {clock, N, Ms}}   -> Owner ! {csp_clock, N, Ms};
		_                      -> ok
	    end;
	_ -> ok
    end.

%% {var,Name,V} | {digital,Name,V} | {analog,Name,V} | {object,Name,[...]}
%%
%% An ARRAY element after the first arrives named with its subscript:
%% `#analog P[10]:16` is {analog,"P",V0} and then {analog,"P[1]",V1} and on.
%% The head cannot be told from a scalar, so it is kept under its bare name AND
%% offered as [0]; the widget side asks for whichever it declared. A node's
%% state (csp_node) names the head P[0], and it is offered as P as well.
flat(Vals) -> lists:append([head(E) || E <- lists:flatten([fv(V) || V <- Vals])]).

fv({object, _Name, Inner}) -> [fv(V) || V <- Inner];
fv({_Kind, Name, Value})   -> [{Name, Value}];
fv(_)                      -> [].

head({Name, V}) ->
    case lists:member($[, Name) of
	true ->
	    case lists:suffix("[0]", Name) of
		true  -> [{Name, V}, {lists:sublist(Name, length(Name) - 3), V}];
		false -> [{Name, V}]
	    end;
	false -> [{Name, V}, {elem(Name, 0), V}]
    end.

elem(Base, N) -> Base ++ "[" ++ integer_to_list(N) ++ "]".

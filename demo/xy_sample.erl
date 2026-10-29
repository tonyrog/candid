%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    Simple 16 bit sample sender using alsa samples module
%%% @end
%%% Created :  4 Oct 2026 by Tony Rogvall <tony@rogvall.se>

-module(xy_sample).
-export([start/1, start/2]).

start(N) when N >= 0 ->
    start(N, [{max_samples, N}, 
	      {rate, 10},
	      {chan,0,0},
	      {wave,0,[#{form=>triangle,freq=>0.5}]},
	      {chan,1,1},
	      {wave,1,[#{form=>sine,freq=>1.0}]}
	     ]).

start(N, Config) when N >= 0, is_list(Config) ->
    Tmo = proplists:get_value(timeout, Config, infinity),
    Max = proplists:get_value(max_samples, Config),
    Config1 = proplists:delete(timeout, Config),
    Config2 = proplists:delete(max_samples, Config1),

    W = alsa_samples:wave_new(),
    ok = alsa_samples:set_wave_def(W, Config2),
    TRef = start_timer(Tmo),
    alsa_samples:wave_set_state(W, running),
    Remain = if Max =:= undefined -> 16#ffffffff; true -> Max end,
    {ok, Socket} = gen_tcp:connect("127.0.0.1", 5555, []),
    Rate = proplists:get_value(rate, Config, 10),   %% 10 hz default
    Delay = trunc((1/Rate)*1000),
    R = send_samples(W, Socket, Delay, Remain, TRef),
    gen_tcp:close(Socket),
    R.

start_timer(infinity) ->
    false;
start_timer(Timeout) ->
    erlang:send_after(Timeout, self(), stop).

send_samples(W, Socket, Delay, Remain, TRef) when Remain > 0 ->
    Channels = 2, Samples = 1,
    {_, _Info, Sample} = alsa_samples:wave(W, s16_be, Channels, Samples),
    gen_tcp:send(Socket, Sample),
    receive
	stop -> 
	    ok
    after Delay ->
	    send_samples(W, Socket, Delay, Remain-2, TRef)
    end;
send_samples(_W, _Socket, _Delay, _Remain, _Ref) ->
    ok.

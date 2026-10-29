# candid

The candyspeak panel.

The smallest complete loop: a switch, a lamp, and a trace, in a browser, driving
a real `csp` process.

    make            # build (parser included, only when the .xrl/.yrl change)
    make test       # run the whole loop with no browser
    make run        # start both servers and print the URL

Then open <http://localhost:8080/panel.html> and pick a program from the menu.

**Two servers, and they are not interchangeable.** `wse_server` speaks websocket
on `/websession` and nothing else -- ask it for a page over plain HTTP and its
handshake falls out of a `case` with a `case_clause` on the header record. So
`candid:start/0` also starts an inets httpd with this `priv/` as its document
root, and **aliases wse's own `priv/` at `/js`** so `ej.js` and `wse.js` are
served from wherever the wse that is running actually lives. Copying them in is
what one usually does, and then they quietly drift from the wse serving the
socket.

## What it does

`demo/gate.csp` is three lines:

    #digital Button in pullup 2
    #digital Led    out       13

    Led = Button

Press the switch and the lamp lights **one cycle later**. The trace is there to
show that delay, because it is the thing about candyspeak that surprises people
who arrive from C: the rule is re-evaluated every cycle, it does not run where
it is written.

`demo/latch.csp` is the same file with one character added:

    Led = 1 ? Button

`?` makes the assignment conditional, and a guarded rule does **nothing** when
its guard is false -- so Led keeps what it had. Press the switch and let go and
the lamp stays lit. Open both demos in turn and the difference is one sample on
the trace: Button returns to zero, Led does not.

That is the second thing that catches people out, and it is worth showing early
precisely because it looks like a broken program.

## Picking a program

The menu lists every `.csp` in `demo/` and in the tree's `examples/`. Choosing
one closes that csp, tears the panel down and rebuilds it from the new file's
declarations, so nothing is shared between programs.

`traffic.csp` is a good next one to look at. A file with no digital, analog or
field declarations says what it does declare instead -- an empty panel
otherwise looks like a failure.

A file can also be passed straight from the page:

    Wse.start('candid', 'run', ["panel", "demo/latch.csp"]);

## The panel is derived, not configured

There is no layout file. `candyspeak:parse/1` gives the declarations and the
direction in them decides the widget:

| declaration              | widget                             |
|--------------------------|------------------------------------|
| `digital in`             | a switch to press                  |
| `digital out`            | a lamp, coloured by its name       |
| `analog in :W`           | a slider, range 0..2^W-1           |
| `analog out :W`          | a meter, full scale 2^W-1          |
| `analog` on **port 9**   | one cell of a horizontal RGB strip |

Add a declaration to the `.csp` file and the widget appears. That is the whole
of `candid:widgets/1`, and it is why there is no second file to keep in step
with the program. Fields are wired up too; variables are one more clause.

What the declaration cannot say -- momentary or latching, a dial or a slider, a
colour, a label, a unit -- is said next to it with `#annotate panel`:

    #annotate panel IndoorTemp kind=dial min=-200 max=400 scale=0.1 unit="°C"

**[doc/candid.md](doc/candid.md) is the reference**: every widget, every
key, which keys apply to which widget, and the XY plot.

The width comes from the declaration's resolution, so `#analog Light:10 in 0:8`
is a 0..1023 slider without anyone saying so.

**Port 9 is an assumption, not something the language says.** On the CPX it is
the pixel strip, where the 16 bits of `#analog P0:16 out unsigned 9:0` are an
RGB565 colour rather than a magnitude. That is why the mapping lives in
`widget/1` next to a comment and not in the parser -- when there is a real way
to declare a pixel, this is the line that changes.

A slider is an **input**, so csp does not own its position: the readout follows
the program but the control stays where your hand left it. Otherwise dragging it
would fight the cycle that writes it back.

**Lamps take their colour from the name** unless `color=` says otherwise. `Red`, `Yellow`, `Green`, `Blue`,
`White` and the Swedish spellings are recognised anywhere in the name; anything
else is red, which is what a bare indicator LED usually is. The declaration says
`out 5` and nothing about colour, so the name is the only thing that knows -- and
a traffic light whose three lamps all glow green is much harder to read than one
that looks like a traffic light. `candid:hue/1`.

**All of port 9 is one horizontal row**, because that is what the strip is on the
board. One swatch per line neither looks like the hardware nor lets you watch a
pattern travel along it, which is the whole of what `cpx_ball.csp` does. Hover a
cell for its name.

**Arrays are one widget per element.** `#analog P[10]:16 out unsigned 9:0..9`
(that is how `cpx_rotate.csp` declares its strip) becomes `P[0]`..`P[9]`. The
dump names such an array ONCE and then sends one entry per further element with
an **empty name**, so `csp_link:flat/1` numbers them back on -- everything above
it deals in plain names.

**One thing to know about wse:** it encodes a plain Erlang list as a JSON array
and only a flat string as a string. An iolist handed to `setStyle` therefore
arrives as `[["..."],["..."]]` and the style is dropped without an error. That is
why every style built from pieces goes through `style/3`, which flattens, and why
`rgb565/1` flattens at the source.

In the trace, digital is two levels **in the lamp's own colour**, analog is a
height within its row, and a pixel is drawn as the colour itself -- so a running
animation leaves a colour strip across the canvas.

## How it talks to csp

Everything the panel sends is a line a human could type at the prompt:

    > Button = 1

and everything it reads is the machine-readable dump `csp -Q -Lerlang` already
prints:

    {state,9,[{var,"State",1},{digital,"Button",1},{digital,"Led",0}, ...]}.

So the panel is a **view**, not an integration. When it does something
surprising, type the same line at `csp -i` yourself and see which side is wrong.

Two things about that dump are easy to get wrong, and both are why the code
looks the way it does:

* **csp dumps on CHANGE, not every cycle.** A trace driven by dumps freezes as
  soon as the program settles -- exactly when you are staring at it wondering
  why. So `candid` draws on its own tick and merges dumps into a `last` map,
  which also makes a trace hold its level instead of dropping to zero.
* **Only what moved crosses.** csp is started with `--delta`, so a dump after
  the first carries only the leaves that changed (bridgezone: 34 bytes against
  12 KB), and csp never dumps nameless `#local`s. The panel then paints only a
  value that differs from what it already shows: `wse:set` and `setStyle` are
  synchronous, a browser round trip each, and repainting every pin of every
  dump was 1800 calls a second -- that was the lag, not the text format.
* **`/commit` is the tick.** It runs exactly one cycle and prints nothing but
  the dump. `/state` also steps, but adds a page of human text; an empty line
  steps nothing at all.

## Paths

candid's own `demo/` and `priv/` are found from where its beam is.
candyspeak's tree -- `csp`, `examples/`, the manual -- from where csp_tools'
beams are, which is the checkout's top-level `ebin/`; `make CANDYSPEAK=...`
when the checkout is not `~/work/candyspeak`. Override with `CANDYSPEAK`,
`CSP_EXE` and `CANDID_DEMO` when that does not hold -- otherwise the failure is
an `enoent` on a path nobody typed.

`WSE` defaults to `~/erlang/wse`; pass `make WSE=...` for another location. Only
the code path uses it -- the scripts come from wherever `code:which(wse)` says.

## How csp is started

An Erlang **port**, not `os:cmd`:

    open_port({spawn_executable, Exe},
	      [{args, ["-i", "--no-eeprom", "-Q", "-Lerlang",
		       "--virtual-time" | Files]},
	       exit_status, use_stdio, stderr_to_stdout, {line, 4096}])

so the panel writes lines into its stdin and reads dumps back, and the process
is owned rather than fired off.

**No `--virtual-time`.** It jumps the clock to the next timer deadline, so a
500 ms phase fires on every tick: measured, `traffic.csp` changed phase every
202 ms with the flag and every 1161 ms without it. Watching it in wall time is
the point, and real time is what csp does when the flag is absent.

**Ending it takes more than closing the port.** csp's own help says it: EOF ends
the prompt, not the program -- close the pipe and it keeps running. So there are
two belts:

* `csp_link` traps exits, and whether the message is `close` (a file was picked)
  or `{'EXIT', Owner, _}` (the tab was shut), it sends `/quit` and waits for the
  exit status, falling back to closing the port and a SIGTERM.
* csp is started with **`--exit-on-eof`**, which makes it quit when stdin closes
  instead of running on to settling.

Getting the first wrong leaves one csp per page load. The original sent `/quit`
and then went back to its receive loop, so the process never died and the port
never closed; worse, when the panel died the link killed `csp_link` before it
had read `close` at all, so nothing was ever sent.

**Still not covered:** the VM dying without running any Erlang code -- Ctrl-C
then `a`, or `kill -9` on erl. `--exit-on-eof` does not save that case, because
Erlang does not close the pipe on the way out. The leftover csp is left holding
a pipe whose write end is already gone and never sees EOF. `pkill -x csp` if it
happens; the ordered paths above are leak-free (`make test` ends on zero).

## Next

The trace is the part worth extending first. A second row per rule showing when
its guard was true would turn "why did this happen" into something you can see,
and the dependency graph csp already builds for reactive dispatch (`es.edg`) is
what would drive it.

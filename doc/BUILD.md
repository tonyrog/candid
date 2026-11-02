# Building a standalone candid

servator packages the RUNNING system: what is loaded, and how it was
started. `-s candid_wx start0` loads everything a package needs without
opening a window (varp for the proofs; ellm, ssl and friends for the chat;
wse), and servator turns it into `-s candid_wx start` in the package. The
package's `csp` is the one in csp_tools' `priv/` -- the host's own build --
and its `lib/`, `examples/` and manual come from there too (in a checkout
`priv/` holds links into the tree; servator copies through them).

Proofs run varp in an `erl` of the package's own erts
(`candyspeak_varp:varp_cmd/0`), so nothing outside the package is needed.
`VARP_SH` still wins when it is set.

A user's configuration is `~/.candid.config` (the ellm key for the chat, see
doc/candid.md); the package writes an empty one the first time. New programs
the chat makes go to `~/candid/` when the package itself cannot be written.

## What a build machine needs

* Erlang/OTP with wx, and these on the code path (`ERL_LIBS`, or the
  Makefile's defaults under `~/erlang`): candyspeak's `csp_tools` (its `ebin/`
  and a built `csp`), wse, rester, uart, ellm, varp, servator.
* `make` in candyspeak first: `csp` and `ebin/` for this machine.

## Linux: an AppImage

    make appimage          # -> Candid-<vsn>-x86_64.AppImage

Needs `appimagetool` on the PATH. Tried: it starts in a clean environment (no
ERL_LIBS, an empty HOME), runs its own csp, and proves with its own varp.

## macOS: a .app in a .dmg (not tried yet)

    make osxapp            # -> Candid-<vsn>.dmg

Needs Xcode's command line tools (cc, hdiutil) and `priv/candid.png` for the
icon (there is none yet).

csp itself (candyspeak `make`) has been made ready for a Mac, untried there:

* **the pty** (`--uart=pty`): `posix_openpt`, the far end's name by
  `TIOCPTYGNAME`, and the old BSD `/dev/pty[p-w][0-9a-f]` if that fails -- as
  the uart application does it. The POSIX path was run on Linux.
* **sockets**: no `SOCK_NONBLOCK` in `socket()` and no `MSG_NOSIGNAL` -- an
  fcntl, and `SO_NOSIGPIPE` on the socket.
* **the image registry**: Mach-O's section is `"__DATA,csp_images"` and its
  bounds are `section$start$__DATA$csp_images` / `section$end$...`.
* SocketCAN is Linux only; without it csp says so and runs on.

clang does not know two of the gcc warnings in the Makefile
(`-Wshift-overflow=2`, `-Wenum-conversion`) and says so; that is noise.

## Windows (not there yet)

Two pieces are missing:

* **csp has no Windows port.** The panel talks to csp over stdin and stdout,
  so the least that is needed is the console and the clock -- a
  `port/csp_win32.c` beside `csp_linux.c`; tcp, uart and the pty can follow.
* **servator's win32 launcher is a FIXME** (`make_win32app_exec`); varp's
  Makefile copies a prebuilt `Varp.exe` into the release instead.

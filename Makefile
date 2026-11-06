# candid, the candyspeak panel. On the code path it needs csp_tools (the
# parser, candyspeak_varp, csp_list... -- candyspeak's ebin/, built by its
# utils/Makefile), wse (the remote DOM) and this. uart is for a node on a
# serial line, and only then. ellm (and the rester it talks through) is for
# the chat, and only then: without it on the path there is no chat button.
#
# With ERL_LIBS=~/erlang the apps there are found by themselves; the -pa
# below names them anyway, so a plain shell works too. csp_tools lives in
# the candyspeak checkout, whose name is not the app's, so it is always -pa.

CANDYSPEAK ?= $(HOME)/work/candyspeak
WSE    ?= $(HOME)/erlang/wse
UART   ?= $(HOME)/erlang/uart
ELLM   ?= $(HOME)/erlang/ellm
RESTER ?= $(HOME)/erlang/rester
VARP   ?= $(HOME)/erlang/varp

ERLC   = erlc
EBIN   = ebin
PA     = -pa $(EBIN) -pa $(CANDYSPEAK)/ebin -pa $(WSE)/ebin -pa $(UART)/ebin \
	 -pa $(ELLM)/ebin -pa $(RESTER)/ebin -pa $(VARP)/ebin
export CANDYSPEAK

all: csp_tools
	@if [ -d "src" -a -f "src/Makefile" ]; then (cd src && $(MAKE) all); fi

# utils/Makefile knows what is stale; asking it every time costs nothing and
# keeps one set of rules for the tree's beams.
csp_tools:
	@$(MAKE) --no-print-directory -s -C $(CANDYSPEAK)/utils

run: all
	erl -s can $(PA) -s candid -config candid.config

# The same panel in a window of its own (wx), no browser.
wx: all
	erl -s can $(PA) -s candid_wx -config candid.config

# The stub wse must shadow the real one. Each -pa prepends, so the LAST one
# given wins -- test/ebin goes at the end, not the front.
test: all
	mkdir -p test/ebin
	$(ERLC) -o test/ebin test/wse.erl test/panel_test.erl test/fake_llm.erl
	CANDID_SETTINGS=/dev/null CSP_EXE=$(CANDYSPEAK)/csp \
	  erl -noshell $(PA) -pa test/ebin -s panel_test run

# A standalone candid, as varp makes its own (servator, which packages the
# running system): an AppImage on Linux, a .app and a .dmg on macOS. The
# package's csp is the one in csp_tools' priv/ -- the host's build.
APP      = candid
APPL     = Candid
VSN      = $(shell git describe --always --tags)
MACHINE  = $(shell uname -m)
SERVATOR ?= $(HOME)/erlang/servator
PACK     = erl -noshell $(PA) -pa $(SERVATOR)/ebin -s candid_wx start0 \
	   -s servator

appimage: all
	$(PACK) make_appimage $(APP) -s erlang halt
	for b in beam.smp epmd erlc erl_child_setup erlexec escript heart \
		 inet_gethost; do \
	    [ -f $(APP).AppDir/bin/$$b ] && strip $(APP).AppDir/bin/$$b || true; \
	done
	appimagetool -n $(APP).AppDir
	mv $(APPL)-$(MACHINE).AppImage $(APPL)-$(VSN)-$(MACHINE).AppImage

osxapp: all
	$(PACK) make_osxapp $(APP) -s erlang halt
	mkdir -p tmpdist
	rm -rf tmpdist/$(APPL).app
	mv $(APPL).app tmpdist/
	(cd tmpdist/; $(SERVATOR)/priv/make_icns ../priv/$(APP).png)
	rm -rf tmpdist/AppIcon.iconset
	mv tmpdist/AppIcon.icns tmpdist/$(APPL).app/Contents/Resources/
	hdiutil create tmp.dmg -ov -volname "$(APPL)" -fs HFS+ -srcfolder "./tmpdist/"
	hdiutil convert -format UDZO -o $(APPL)-$(VSN).dmg tmp.dmg
	rm tmp.dmg

# candid_wx in a virtual display: the loop through a real window.
test-wx: all
	mkdir -p test/ebin
	$(ERLC) -o test/ebin test/wx_test.erl
	@CANDID_SETTINGS=/dev/null CSP_EXE=$(CANDYSPEAK)/csp xvfb-run -a -s "-screen 0 1440x940x24" \
	  erl -noshell $(PA) -pa test/ebin -s wx_test run > test/wx.out 2>&1; \
	  s=$$?; grep -v 'Gtk-WARNING' test/wx.out | grep -v '^$$'; exit $$s

# Generate a varp model from a .csp and check it has transitions at all. The
# consistency probe is not optional: an inconsistent `next' makes every property
# provable, which looks authoritative and means nothing.
VARP_SH ?= $(HOME)/erlang/varp/priv/varp.sh
CSP     ?= demo/home.csp

# Output is <name>_gen.varp, NOT <name>.varp: the hand-written models in demo/
# are commentary and were overwritten once already by a careless default.
varp: all
	erl -noshell $(PA) -eval \
	  'candyspeak_varp:file("$(CSP)", "$(basename $(CSP))_gen.varp"), halt().'
	@echo "wrote $(basename $(CSP))_gen.varp"

varp-check: all
	erl -noshell $(PA) -eval \
	  'candyspeak_varp:check("$(CANDYSPEAK)/examples/*.csp", "$(VARP_SH)"), halt().'

clean:
	rm -f $(EBIN)/*.beam $(EBIN)/*.app test/ebin/*.beam

.PHONY: all csp_tools run wx test test-wx appimage osxapp varp varp-check clean

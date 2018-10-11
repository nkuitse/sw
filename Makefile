include config.mk

build: build/$(PROG)

configure: config.mk

config.mk: config.mk.def
	cp $< $@
	$(VISUAL) $<

build/$(PROG): configure sw
	install -d build
	bin/build PROG=$(PROG) ENV_VAR=$(ENV_VAR) PREFIX=$(PREFIX) DB_DIR=$(DB_DIR) PLUGIN_DIR=$(PLUGIN_DIR) < sw > $@

clean:
	rm -Rf build

install: install-prog install-plugins
	
install-prog: build
	install -d $(PREFIX)/bin
	install $(PROG) $(PREFIX)/bin/

install-plugins:
	install -d $(PLUGIN_DIR)
	install -m 644 plugins/* $(PLUGIN_DIR)/

.PHONY: configure build clean install

include config.mk

build: sw
	@echo "Nothing to build; use \`make install' to install"

install: sw
	install $< $(PREFIX)/bin

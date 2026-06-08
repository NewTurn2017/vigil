PREFIX ?= /usr/local
BIN := br
LIB := Sources/Brightness.swift Sources/CLI.swift Sources/Agent.swift Sources/Sleep.swift
PLIST := com.genie.br
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/$(PLIST).plist
LOG := $(HOME)/Library/Logs/br-agent.log
DOMAIN := gui/$(shell id -u)
SUDOERS := /etc/sudoers.d/br

.PHONY: all test install uninstall hotkey-install hotkey-uninstall sleep-setup sleep-teardown clean

all: $(BIN)

$(BIN): $(LIB) Sources/main.swift
	swiftc -O -o $(BIN) $(LIB) Sources/main.swift

br-test: $(LIB) Tests/main.swift
	swiftc -o br-test $(LIB) Tests/main.swift

test: br-test
	./br-test

install: $(BIN)
	install -d "$(PREFIX)/bin"
	install -m 755 $(BIN) "$(PREFIX)/bin/$(BIN)"
	@echo "installed $(PREFIX)/bin/$(BIN)"

uninstall:
	rm -f "$(PREFIX)/bin/$(BIN)"

hotkey-install:
	@test -x "$(PREFIX)/bin/$(BIN)" || { echo "run 'make install' (maybe with sudo, or PREFIX=\$$HOME/.local) first"; exit 1; }
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed -e 's#__BR_PATH__#$(PREFIX)/bin/$(BIN)#' -e 's#__LOG_PATH__#$(LOG)#' \
		launchd/$(PLIST).plist.template > "$(LAUNCH_AGENT)"
	launchctl bootout $(DOMAIN)/$(PLIST) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) "$(LAUNCH_AGENT)"
	launchctl kickstart -k $(DOMAIN)/$(PLIST)
	@echo "hotkey agent loaded (default key: ctrl-opt-cmd-B). Logs: $(LOG)"

hotkey-uninstall:
	launchctl bootout $(DOMAIN)/$(PLIST) 2>/dev/null || true
	rm -f "$(LAUNCH_AGENT)"
	@echo "hotkey agent unloaded"

sleep-setup:
	@u=$${SUDO_USER:-$$(id -un)}; \
		echo "installing sleep-control sudoers rule for user: $$u"; \
		sed "s#__USER__#$$u#" sudoers/br.sudoers.template > /tmp/br.sudoers
	sudo visudo -cf /tmp/br.sudoers
	sudo install -m 0440 -o root -g wheel /tmp/br.sudoers "$(SUDOERS)"
	@rm -f /tmp/br.sudoers
	@echo "sleep control enabled. Now 'br off' enables clamshell (no-sleep), 'br on' restores sleep."
	@echo "test: br off; pmset -g | grep SleepDisabled   # -> 1 ; then br on -> 0"

sleep-teardown:
	sudo rm -f "$(SUDOERS)"
	@echo "sleep control disabled (removed $(SUDOERS)). br off/on no longer touch sleep."

clean:
	rm -f $(BIN) br-test

# Copyright (C) 2026 Nye Liu
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

SHELL := /bin/bash

DEST ?= /etc/openvpn/server
OPENVPN ?= /usr/sbin/openvpn
EASYRSA ?= /usr/share/easy-rsa/easyrsa
CERT_DAYS ?= 3650

SITE_CONF := site.conf
VARS_MK := server/vars.mk

$(VARS_MK): $(SITE_CONF) gen-config.py
	./gen-config.py make-vars $@

$(SITE_CONF):
	./gen-config.py init-site

include $(VARS_MK)

CONFS := $(addprefix server/server-,$(addsuffix .conf,$(PROTOS)))
UNITS := $(addprefix openvpn-server@server-,$(PROTOS))
CLIENT_OVPNS := $(foreach p,$(PROTOS),$(addprefix client/,$(addsuffix $(if $(filter tcp,$(p)),.tcp).ovpn,$(CLIENTS))))
NFT := $(if $(PROTOS),server/openvpn.nft)

PKI := easy-rsa/pki
SERIAL := $(PKI)/serial
CA_CRT := $(PKI)/ca.crt
CA_KEY := $(PKI)/private/ca.key
SERVER_CRT := $(PKI)/issued/$(SERVER_CN).crt
SERVER_KEY := $(PKI)/private/$(SERVER_CN).key
TC_KEY := server/tc.key
CRL := $(PKI)/crl.pem

NEED_USER := test "$$(id -u)" -ne 0 || { echo "generate PKI as non-root; run make, then sudo make deploy"; exit 1; }
NEED_EASYRSA := test -x "$(EASYRSA)" || { echo "missing $(EASYRSA); apt install easy-rsa"; exit 1; }
NEED_TUN := test -e /dev/net/tun && ( exec 7<>/dev/net/tun ) 2>/dev/null || { echo "TUN device missing; enable /dev/net/tun"; exit 1; }

CONF_DEPS := server.conf.in gen-config.py $(SITE_CONF)

# Optional CLI path. Not a site.conf key. Empty = search PATH, then
# /usr/sbin/bootstash, then /usr/local/sbin/bootstash.
BOOTSTASH_CLI ?=

.DEFAULT_GOAL := all
.PHONY: all confs pki pki-clean clean distclean clients maybe-bootstash bootstash dryrun deploy install-pki revoke
.SECONDARY:

all: confs pki clients

confs: $(CONFS) $(NFT)

clean:
	rm -rf client
	rm -f server/server-*.conf server/openvpn.nft server/vars.mk server/*.tmp

distclean pki-clean: clean
	rm -rf server $(PKI)

pki: $(CA_CRT) $(SERVER_CRT) $(TC_KEY) $(CRL)

clients: $(CLIENT_OVPNS)
	@$(if $(filter no,$(BOOTSTASH)),:,$(MAKE) --no-print-directory maybe-bootstash)

# BOOTSTASH=auto (default): put when the CLI exists. Failures stay in client/.
# BOOTSTASH=no: skip. make bootstash requires a successful put.
maybe-bootstash:
	@cli="$(BOOTSTASH_CLI)"; \
	if [ -z "$$cli" ]; then \
		cli=$$({ command -v bootstash 2>/dev/null && exit 0; \
			test -x /usr/sbin/bootstash && echo /usr/sbin/bootstash && exit 0; \
			test -x /usr/local/sbin/bootstash && echo /usr/local/sbin/bootstash; }); \
	fi; \
	if [ -z "$$cli" ] || [ -z "$(CLIENT_OVPNS)" ]; then \
		exit 0; \
	fi; \
	$(NEED_USER); \
	echo "$$cli put -t . $(CLIENT_OVPNS)"; \
	$$cli put -t . $(CLIENT_OVPNS) || echo "bootstash put failed; profiles remain in client/"

bootstash: $(CLIENT_OVPNS)
	@$(NEED_USER)
	@cli="$(BOOTSTASH_CLI)"; \
	if [ -z "$$cli" ]; then \
		cli=$$({ command -v bootstash 2>/dev/null && exit 0; \
			test -x /usr/sbin/bootstash && echo /usr/sbin/bootstash && exit 0; \
			test -x /usr/local/sbin/bootstash && echo /usr/local/sbin/bootstash; }); \
	fi; \
	test -n "$$cli" || { echo "bootstash CLI not found (PATH, /usr/sbin, /usr/local/sbin)"; exit 1; }; \
	test -n "$(CLIENT_OVPNS)" || { echo "no client profiles"; exit 1; }; \
	echo "$$cli put -t . $(CLIENT_OVPNS)"; \
	$$cli put -t . $(CLIENT_OVPNS)

server/server-%.conf: $(CONF_DEPS)
	./gen-config.py server $* $@

server/openvpn.nft: openvpn.nft.in gen-config.py $(SITE_CONF)
	./gen-config.py nft $@

$(SERIAL):
	@$(NEED_USER)
	@$(NEED_EASYRSA)
	mkdir -p easy-rsa
	cd easy-rsa && $(EASYRSA) --batch init-pki

$(CA_CRT) $(CA_KEY) &: | $(SERIAL)
	@$(NEED_USER)
	@$(NEED_EASYRSA)
	cd easy-rsa && $(EASYRSA) --batch --days=$(CERT_DAYS) --nopass build-ca

$(SERVER_CRT) $(SERVER_KEY) &: $(CA_CRT)
	@$(NEED_USER)
	@$(NEED_EASYRSA)
	cd easy-rsa && $(EASYRSA) --batch --days=$(CERT_DAYS) --nopass --auto-san \
		build-server-full "$(SERVER_CN)"

$(TC_KEY):
	@$(NEED_USER)
	mkdir -p "$(dir $@)"
	$(OPENVPN) --genkey tls-crypt $@
	chmod 600 $@

$(CRL): $(CA_CRT)
	@$(NEED_USER)
	@$(NEED_EASYRSA)
	cd easy-rsa && $(EASYRSA) --batch gen-crl

$(PKI)/issued/%.crt $(PKI)/private/%.key &: $(CA_CRT)
	@$(NEED_USER)
	@$(NEED_EASYRSA)
	cd easy-rsa && $(EASYRSA) --batch --days=$(CERT_DAYS) --nopass build-client-full "$*"

client/%.ovpn: Makefile gen-config.py $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TC_KEY) \
		client.ovpn.in server/server-udp.conf $(SITE_CONF)
	./gen-config.py client "$(SERVER_CN)" "$*" server/server-udp.conf $@

client/%.tcp.ovpn: Makefile gen-config.py $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TC_KEY) \
		client.ovpn.in server/server-tcp.conf $(SITE_CONF)
	./gen-config.py client "$(SERVER_CN)" "$*" server/server-tcp.conf $@

revoke:
	@$(NEED_USER)
	@$(NEED_EASYRSA)
	@test -n "$(CLIENT)" || { echo "usage: make revoke CLIENT=name"; exit 1; }
	@test -f "$(CA_KEY)" || { echo "missing $(CA_KEY); restore PKI first"; exit 1; }
	cd easy-rsa && $(EASYRSA) --batch revoke "$(CLIENT)"
	cd easy-rsa && $(EASYRSA) --batch gen-crl
	@echo "revoked $(CLIENT); sudo make deploy to install the new CRL"

dryrun: all
	@for f in $(CONFS); do b=$$(basename "$$f"); echo "=== $$b ==="; \
		diff -u "$(DEST)/$$b" "$$f" || true; \
	done

# PKI files are sources to copy, not Make deps (sudo must not generate them).
install-pki:
	@test "$$(id -u)" -eq 0 || { echo "need root: sudo make install-pki"; exit 1; }
	@$(NEED_TUN)
	@for f in $(CA_CRT) $(SERVER_CRT) $(SERVER_KEY) $(TC_KEY) $(CRL); do \
		test -f "$$f" || { echo "missing $$f; run make pki first"; exit 1; }; \
	done
	install -d -m 755 "$(DEST)/easy-rsa/pki/issued" "$(DEST)/easy-rsa/pki/private"
	chmod o+x "$(DEST)"
	install -m 644 "$(CA_CRT)" "$(DEST)/easy-rsa/pki/"
	install -m 644 "$(SERVER_CRT)" "$(DEST)/easy-rsa/pki/issued/"
	install -m 600 "$(SERVER_KEY)" "$(DEST)/easy-rsa/pki/private/"
	install -m 600 "$(TC_KEY)" "$(DEST)/tc.key"
	install -m 644 "$(CRL)" "$(DEST)/crl.pem"

deploy: install-pki $(CONFS)
	@test "$$(id -u)" -eq 0 || { echo "need root: sudo make deploy"; exit 1; }
	@$(NEED_TUN)
	@test -n "$(CONFS)" || { echo "ENABLE_UDP and ENABLE_TCP are both off"; exit 1; }
	install -d -m 755 "$(DEST)"
	install -m 644 $(CONFS) "$(DEST)/"
	@if [ -n "$(IPP_FILES)" ]; then \
		for f in $(IPP_FILES); do \
			install -d -o nobody -g adm -m 750 "$$(dirname "$$f")"; \
			if [ ! -e "$$f" ]; then \
				install -o nobody -g adm -m 640 /dev/null "$$f"; \
			else \
				chown nobody:adm "$$f"; \
				chmod 640 "$$f"; \
			fi; \
		done; \
	fi
	systemctl daemon-reload
	systemctl try-restart $(UNITS)

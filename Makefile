SHELL := /bin/bash
# Site settings: cp examples/config.mk config.mk

-include config.mk

DEST ?= /etc/openvpn/server
# REMOTE is required (hostname clients dial). No example.com default.
ifeq ($(strip $(REMOTE)),)
$(error REMOTE is required; set it in config.mk)
endif
ifeq ($(REMOTE),example.com)
$(error REMOTE=example.com is not allowed; set a real hostname in config.mk)
endif
# Cert CN / verify-x509-name. Follows REMOTE unless set.
SERVER_CN ?= $(REMOTE)
# login that owns the process (SUDO_USER if uid 0)
CLIENTS ?= $(shell test "$$(id -u)" -eq 0 && printf '%s\n' "$${SUDO_USER:-$$(id -un)}" || id -un)
OPENVPN ?= /usr/sbin/openvpn
EASYRSA ?= /usr/share/easy-rsa/easyrsa

ENABLE_UDP ?= yes
ENABLE_TCP ?= no
UDP_PORT ?= 1194
TCP_PORT ?= 443
UDP_DEV ?= tun0
TCP_DEV ?= tun1
UDP_POOL ?= 10.8.19.0 255.255.255.0
TCP_POOL ?= 10.8.20.0 255.255.255.0
LAN_ROUTE ?=
DNS ?=
STATE_DIR ?= /var/lib/openvpn-server
UDP_IPP ?= $(STATE_DIR)/ipp.txt
TCP_IPP ?= $(STATE_DIR)/ipp-tcp.txt
MSSFIX ?= 1360
REDIRECT_GATEWAY ?= redirect-gateway def1 bypass-dhcp
PORT_SHARE ?=
CERT_DAYS ?= 3650

export REMOTE

# Listeners. ENABLE_*=yes includes that proto (udp / tcp).
PROTOS := $(strip \
	$(if $(filter yes,$(ENABLE_UDP)),udp) \
	$(if $(filter yes,$(ENABLE_TCP)),tcp))
CONFS := $(addprefix server/server-,$(addsuffix .conf,$(PROTOS)))
UNITS := $(addprefix openvpn-server@server-,$(PROTOS))
CLIENT_OVPNS := $(foreach p,$(PROTOS),$(addprefix client/,$(addsuffix $(if $(filter tcp,$(p)),.tcp).ovpn,$(CLIENTS))))
IPP_FILES := $(foreach p,$(PROTOS),$(if $(filter tcp,$(p)),$(TCP_IPP),$(UDP_IPP)))

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

REDIRECT_GATEWAY_PUSH := $(if $(strip $(REDIRECT_GATEWAY)),push "$(REDIRECT_GATEWAY)")
PORT_SHARE_LINE := $(if $(strip $(PORT_SHARE)),port-share $(PORT_SHARE))
LAN_ROUTE_PUSH := $(if $(strip $(LAN_ROUTE)),push "route $(LAN_ROUTE)")
DNS_PUSH := $(if $(strip $(DNS)),push "dhcp-option DNS $(DNS)")
BLOCK_OUTSIDE_DNS_PUSH := $(if $(strip $(DNS)),push "block-outside-dns")

CONF_DEPS := server.conf.in gen-config.py Makefile $(wildcard config.mk)

.DEFAULT_GOAL := all
.PHONY: all confs pki pki-clean clean distclean clients dryrun deploy install-pki revoke
.SECONDARY:

all: confs pki clients

confs: $(CONFS)

# $(call emit_conf,proto,port,dev,pool,ipp,port_share,exit_notify)
define emit_conf
	mkdir -p "$(dir $@)"
	SERVER_CN='$(SERVER_CN)' \
	PROTO='$(1)' PORT='$(2)' DEV='$(3)' POOL='$(4)' IPP='$(5)' \
	PORT_SHARE='$(6)' EXIT_NOTIFY='$(7)' \
	LAN_ROUTE_PUSH='$(LAN_ROUTE_PUSH)' \
	DNS_PUSH='$(DNS_PUSH)' \
	BLOCK_OUTSIDE_DNS_PUSH='$(BLOCK_OUTSIDE_DNS_PUSH)' \
	MSSFIX='$(MSSFIX)' \
	REDIRECT_GATEWAY_PUSH='$(REDIRECT_GATEWAY_PUSH)' \
	./gen-config.py server > $@.tmp
	mv $@.tmp $@
endef

clean:
	rm -rf client
	rm -f server/server-*.conf server/openvpn.nft server/*.tmp

distclean pki-clean: clean
	rm -rf server $(PKI)

pki-clean: distclean

pki: $(CA_CRT) $(SERVER_CRT) $(TC_KEY) $(CRL)

clients: $(CLIENT_OVPNS)

server/server-udp.conf: $(CONF_DEPS)
	$(call emit_conf,udp,$(UDP_PORT),$(UDP_DEV),$(UDP_POOL),$(UDP_IPP),,explicit-exit-notify 1)

server/server-tcp.conf: $(CONF_DEPS)
	$(call emit_conf,tcp,$(TCP_PORT),$(TCP_DEV),$(TCP_POOL),$(TCP_IPP),$(PORT_SHARE_LINE),)

$(SERIAL):
	@$(NEED_USER)
	@$(NEED_EASYRSA)
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
		client.ovpn.in server/server-udp.conf $(wildcard config.mk)
	mkdir -p "$(dir $@)"
	./gen-config.py client "$(SERVER_CN)" "$*" server/server-udp.conf $@.tmp
	mv $@.tmp $@
	chmod 600 $@

client/%.tcp.ovpn: Makefile gen-config.py $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TC_KEY) \
		client.ovpn.in server/server-tcp.conf $(wildcard config.mk)
	mkdir -p "$(dir $@)"
	./gen-config.py client "$(SERVER_CN)" "$*" server/server-tcp.conf $@.tmp
	mv $@.tmp $@
	chmod 600 $@

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
	@for f in $(IPP_FILES); do \
		install -d -o nobody -g adm -m 750 "$$(dirname "$$f")"; \
		if [ ! -e "$$f" ]; then \
			install -o nobody -g adm -m 640 /dev/null "$$f"; \
		else \
			chown nobody:adm "$$f"; \
			chmod 640 "$$f"; \
		fi; \
	done
	systemctl daemon-reload
	systemctl try-restart $(UNITS)

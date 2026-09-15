SHELL := /bin/bash
# Site settings: cp examples/config.mk config.mk

-include config.mk

DEST ?= /etc/openvpn/server
SERVER_CN ?= example.com
REMOTE ?= $(SERVER_CN)
# login that owns the process (SUDO_USER if uid 0)
CLIENTS ?= $(shell test "$$(id -u)" -eq 0 && printf '%s\n' "$${SUDO_USER:-$$(id -un)}" || id -un)
OPENVPN ?= /usr/sbin/openvpn
EASYRSA := ./easyrsa

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
UDP_IPP ?= /var/log/openvpn/ipp.txt
TCP_IPP ?= /var/log/openvpn/ipp-tcp.txt
CIPHER ?= AES-256-CBC
MSSFIX ?= 1360
REDIRECT_GATEWAY ?= redirect-gateway def1 bypass-dhcp
PORT_SHARE ?=

export REMOTE

# server.conf is the Debian sample (not a unit). Live units from ENABLE_*.
CONFS :=
UNITS :=
CLIENT_OVPNS :=
ifeq ($(ENABLE_UDP),yes)
CONFS += server-udp.conf
UNITS += openvpn-server@server-udp
CLIENT_OVPNS += $(addprefix client/,$(addsuffix .ovpn,$(CLIENTS)))
endif
ifeq ($(ENABLE_TCP),yes)
CONFS += server-tcp.conf
UNITS += openvpn-server@server-tcp
CLIENT_OVPNS += $(addprefix client/,$(addsuffix .tcp.ovpn,$(CLIENTS)))
endif

PKI := easy-rsa/pki
SERIAL := $(PKI)/serial
CA_CRT := $(PKI)/ca.crt
CA_KEY := $(PKI)/private/ca.key
SERVER_CRT := $(PKI)/issued/$(SERVER_CN).crt
SERVER_KEY := $(PKI)/private/$(SERVER_CN).key
DH_PEM := $(PKI)/dh.pem
TA_KEY := server/ta.key

NEED_USER := test "$$(id -u)" -ne 0 || { echo "generate PKI as non-root; run make, then sudo make deploy"; exit 1; }

REDIRECT_GATEWAY_PUSH := $(if $(strip $(REDIRECT_GATEWAY)),push "$(REDIRECT_GATEWAY)")
PORT_SHARE_LINE := $(if $(strip $(PORT_SHARE)),port-share $(PORT_SHARE))
LAN_ROUTE_PUSH := $(if $(strip $(LAN_ROUTE)),push "route $(LAN_ROUTE)")
DNS_PUSH := $(if $(strip $(DNS)),push "dhcp-option DNS $(DNS)")

CONF_DEPS := server.conf.in subst Makefile $(wildcard config.mk)

.DEFAULT_GOAL := all
.PHONY: all confs pki pki-clean clients dryrun deploy install-pki
.SECONDARY:

all: confs pki clients

confs: $(CONFS)

# $(call emit_conf,proto,port,dev,pool,ipp,port_share,exit_notify)
define emit_conf
	SERVER_CN='$(SERVER_CN)' \
	PROTO='$(1)' PORT='$(2)' DEV='$(3)' POOL='$(4)' IPP='$(5)' \
	PORT_SHARE='$(6)' EXIT_NOTIFY='$(7)' \
	LAN_ROUTE_PUSH='$(LAN_ROUTE_PUSH)' \
	DNS_PUSH='$(DNS_PUSH)' \
	CIPHER='$(CIPHER)' \
	MSSFIX='$(MSSFIX)' \
	REDIRECT_GATEWAY_PUSH='$(REDIRECT_GATEWAY_PUSH)' \
	./subst server.conf.in > $@.tmp
	mv $@.tmp $@
endef

pki-clean:
	rm -rf $(PKI) $(TA_KEY) client

pki: $(CA_CRT) $(SERVER_CRT) $(DH_PEM) $(TA_KEY)

clients: $(CLIENT_OVPNS)

server-udp.conf: $(CONF_DEPS)
	$(call emit_conf,udp,$(UDP_PORT),$(UDP_DEV),$(UDP_POOL),$(UDP_IPP),,explicit-exit-notify 1)

server-tcp.conf: $(CONF_DEPS)
	$(call emit_conf,tcp,$(TCP_PORT),$(TCP_DEV),$(TCP_POOL),$(TCP_IPP),$(PORT_SHARE_LINE),)

$(SERIAL):
	@$(NEED_USER)
	cd easy-rsa && $(EASYRSA) --batch init-pki

$(CA_CRT) $(CA_KEY) &: | $(SERIAL)
	@$(NEED_USER)
	cd easy-rsa && $(EASYRSA) --batch --nopass build-ca

$(SERVER_CRT) $(SERVER_KEY) &: $(CA_CRT)
	@$(NEED_USER)
	cd easy-rsa && $(EASYRSA) --batch --nopass --auto-san \
		build-server-full "$(SERVER_CN)"

$(DH_PEM): | $(SERIAL)
	@$(NEED_USER)
	cd easy-rsa && $(EASYRSA) --batch gen-dh

$(TA_KEY):
	@$(NEED_USER)
	mkdir -p $(dir $@)
	$(OPENVPN) --genkey tls-auth $@

$(PKI)/issued/%.crt $(PKI)/private/%.key &: $(CA_CRT)
	@$(NEED_USER)
	cd easy-rsa && $(EASYRSA) --batch --nopass build-client-full "$*"

client/%.ovpn: Makefile client-gen subst $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TA_KEY) \
		client.ovpn.in server-udp.conf $(wildcard config.mk)
	mkdir -p $(dir $@)
	./client-gen "$(SERVER_CN)" "$*" server-udp.conf $@.tmp
	mv $@.tmp $@

client/%.tcp.ovpn: Makefile client-gen subst $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TA_KEY) \
		client.ovpn.in server-tcp.conf $(wildcard config.mk)
	mkdir -p $(dir $@)
	./client-gen "$(SERVER_CN)" "$*" server-tcp.conf $@.tmp
	mv $@.tmp $@

dryrun: $(CONFS)
	@for f in $(CONFS); do echo "=== $$f ==="; \
		diff -u "$(DEST)/$$f" "$$f" || true; \
	done

# PKI files are sources to copy, not Make deps (sudo must not generate them).
install-pki:
	@test "$$(id -u)" -eq 0 || { echo "need root: sudo make install-pki"; exit 1; }
	@for f in $(CA_CRT) $(SERVER_CRT) $(SERVER_KEY) $(DH_PEM) $(TA_KEY); do \
		test -f "$$f" || { echo "missing $$f; run make pki first"; exit 1; }; \
	done
	install -d -m 755 "$(DEST)/easy-rsa/pki/issued" "$(DEST)/easy-rsa/pki/private" "$(DEST)/server"
	install -m 644 "$(CA_CRT)" "$(DEST)/easy-rsa/pki/"
	install -m 644 "$(DH_PEM)" "$(DEST)/easy-rsa/pki/"
	install -m 644 "$(SERVER_CRT)" "$(DEST)/easy-rsa/pki/issued/"
	install -m 600 "$(SERVER_KEY)" "$(DEST)/easy-rsa/pki/private/"
	install -m 600 "$(TA_KEY)" "$(DEST)/server/"

deploy: install-pki $(CONFS)
	@test "$$(id -u)" -eq 0 || { echo "need root: sudo make deploy"; exit 1; }
	@test -n "$(CONFS)" || { echo "ENABLE_UDP and ENABLE_TCP are both off"; exit 1; }
	install -d -m 755 "$(DEST)"
	install -m 644 $(CONFS) "$(DEST)/"
	systemctl daemon-reload
	systemctl try-restart $(UNITS)

SHELL := /bin/bash
# Site settings: cp examples/config.mk config.mk

-include config.mk

DEST ?= /etc/openvpn/server
SERVER_CN ?= example.com
REMOTE ?= $(SERVER_CN)
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
CIPHER ?=
MSSFIX ?= 1360
REDIRECT_GATEWAY ?= redirect-gateway def1 bypass-dhcp
PORT_SHARE ?=
CERT_DAYS ?= 3650

export REMOTE

# server.conf is the Debian sample (not a unit). Live units from ENABLE_*.
CONFS :=
UNITS :=
CLIENT_OVPNS :=
IPP_FILES :=
ifeq ($(ENABLE_UDP),yes)
CONFS += server-udp.conf
UNITS += openvpn-server@server-udp
CLIENT_OVPNS += $(addprefix client/,$(addsuffix .ovpn,$(CLIENTS)))
IPP_FILES += $(UDP_IPP)
endif
ifeq ($(ENABLE_TCP),yes)
CONFS += server-tcp.conf
UNITS += openvpn-server@server-tcp
CLIENT_OVPNS += $(addprefix client/,$(addsuffix .tcp.ovpn,$(CLIENTS)))
IPP_FILES += $(TCP_IPP)
endif

PKI := easy-rsa/pki
SERIAL := $(PKI)/serial
CA_CRT := $(PKI)/ca.crt
CA_KEY := $(PKI)/private/ca.key
SERVER_CRT := $(PKI)/issued/$(SERVER_CN).crt
SERVER_KEY := $(PKI)/private/$(SERVER_CN).key
TC_KEY := tc.key
CRL := $(PKI)/crl.pem

NEED_USER := test "$$(id -u)" -ne 0 || { echo "generate PKI as non-root; run make, then sudo make deploy"; exit 1; }
NEED_EASYRSA := test -x "$(EASYRSA)" || { echo "missing $(EASYRSA); apt install easy-rsa"; exit 1; }
NEED_TUN := test -e /dev/net/tun && ( exec 7<>/dev/net/tun ) 2>/dev/null || { echo "TUN device missing; enable /dev/net/tun"; exit 1; }

REDIRECT_GATEWAY_PUSH := $(if $(strip $(REDIRECT_GATEWAY)),push "$(REDIRECT_GATEWAY)")
PORT_SHARE_LINE := $(if $(strip $(PORT_SHARE)),port-share $(PORT_SHARE))
LAN_ROUTE_PUSH := $(if $(strip $(LAN_ROUTE)),push "route $(LAN_ROUTE)")
DNS_PUSH := $(if $(strip $(DNS)),push "dhcp-option DNS $(DNS)")
BLOCK_OUTSIDE_DNS_PUSH := $(if $(strip $(DNS)),push "block-outside-dns")
CIPHER_LINE := $(if $(strip $(CIPHER)),data-ciphers-fallback $(CIPHER))

CONF_DEPS := server.conf.in subst Makefile $(wildcard config.mk)

.DEFAULT_GOAL := all
.PHONY: all confs pki pki-clean clients dryrun deploy install-pki revoke
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
	BLOCK_OUTSIDE_DNS_PUSH='$(BLOCK_OUTSIDE_DNS_PUSH)' \
	CIPHER_LINE='$(CIPHER_LINE)' \
	MSSFIX='$(MSSFIX)' \
	REDIRECT_GATEWAY_PUSH='$(REDIRECT_GATEWAY_PUSH)' \
	./subst server.conf.in > $@.tmp
	mv $@.tmp $@
endef

pki-clean:
	rm -rf $(PKI) $(TC_KEY) server/ta.key server/tc.key client

pki: $(CA_CRT) $(SERVER_CRT) $(TC_KEY) $(CRL)

clients: $(CLIENT_OVPNS)

server-udp.conf: $(CONF_DEPS)
	$(call emit_conf,udp,$(UDP_PORT),$(UDP_DEV),$(UDP_POOL),$(UDP_IPP),,explicit-exit-notify 1)

server-tcp.conf: $(CONF_DEPS)
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

client/%.ovpn: Makefile client-gen subst $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TC_KEY) \
		client.ovpn.in server-udp.conf $(wildcard config.mk)
	mkdir -p $(dir $@)
	./client-gen "$(SERVER_CN)" "$*" server-udp.conf $@.tmp
	mv $@.tmp $@
	chmod 600 $@

client/%.tcp.ovpn: Makefile client-gen subst $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TC_KEY) \
		client.ovpn.in server-tcp.conf $(wildcard config.mk)
	mkdir -p $(dir $@)
	./client-gen "$(SERVER_CN)" "$*" server-tcp.conf $@.tmp
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

dryrun: $(CONFS)
	@for f in $(CONFS); do echo "=== $$f ==="; \
		diff -u "$(DEST)/$$f" "$$f" || true; \
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

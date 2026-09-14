SHELL := /bin/bash
DEST ?= /etc/openvpn/server
SERVER_CN ?= vpn.internal.curtisfong.org
CLIENTS ?= client
OPENVPN ?= /usr/sbin/openvpn
EASYRSA := ./easyrsa

export SERVER_CN

# server.conf is the Debian sample (not a unit). Live: server-udp / server-tcp.
CONFS := server-udp.conf server-tcp.conf
UNITS := openvpn-server@server-udp openvpn-server@server-tcp
LOGROTATE := logrotate.d/openvpn
LOGROTATE_DEST ?= /etc/logrotate.d/openvpn

PKI := easy-rsa/pki
SERIAL := $(PKI)/serial
CA_CRT := $(PKI)/ca.crt
CA_KEY := $(PKI)/private/ca.key
SERVER_CRT := $(PKI)/issued/$(SERVER_CN).crt
SERVER_KEY := $(PKI)/private/$(SERVER_CN).key
DH_PEM := $(PKI)/dh.pem
TA_KEY := server/ta.key
CLIENT_OVPNS := $(addprefix client/,$(addsuffix .ovpn,$(CLIENTS)))

NEED_USER := test "$$(id -u)" -ne 0 || { echo "generate PKI as non-root; run make, then sudo make deploy"; exit 1; }

.PHONY: all pki pki-clean clients dryrun deploy install-pki
.SECONDARY:

all: pki clients

pki-clean:
	rm -rf $(PKI) $(TA_KEY) client

pki: $(CA_CRT) $(SERVER_CRT) $(DH_PEM) $(TA_KEY)

clients: $(CLIENT_OVPNS)

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

client/%.ovpn: Makefile client-gen $(PKI)/issued/%.crt $(PKI)/private/%.key $(CA_CRT) $(TA_KEY) \
		client.ovpn server-udp.conf
	mkdir -p $(dir $@)
	./client-gen "$*"

dryrun:
	@for f in $(CONFS); do echo "=== $$f ==="; \
		diff -u "$(DEST)/$$f" "$$f" || true; \
	done
	@echo "=== $(LOGROTATE) ==="; diff -u "$(LOGROTATE_DEST)" "$(LOGROTATE)" || true

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

deploy: install-pki
	@test "$$(id -u)" -eq 0 || { echo "need root: sudo make deploy"; exit 1; }
	install -d -m 755 "$(DEST)"
	install -m 644 $(CONFS) "$(DEST)/"
	install -m 644 "$(LOGROTATE)" "$(LOGROTATE_DEST)"
	systemctl daemon-reload
	systemctl try-restart $(UNITS)

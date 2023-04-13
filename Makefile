etc_dir := /usr/local/etc/haproxy
socat_cmd = echo '$(1)' | socat /tmp/api.sock -;
docker_exec = docker exec -i haproxy bash -c $(1)
while_exec = $(call docker_exec,"while true; do $(2) sleep $(1); done")

maps_cmd = echo \
	"$(call socat_cmd,show map)" \
	"$(call socat_cmd,show map $(etc_dir)/maps/config.map)" \
	"$(call socat_cmd,show map $(etc_dir)/maps/rates-by-url.map)" \
	"$(call socat_cmd,show map $(etc_dir)/maps/rates-by-ip.map)"

tables_cmd = echo \
	"$(call socat_cmd,show table st_global)" \
	"$(call socat_cmd,show table st_paths)"


.PHONY: all
all: up

.PHONY: up
up:
	docker-compose up -d

.PHONY: down
down:
	docker-compose down -v

.PHONY: logs
logs:
	docker-compose logs -f

.PHONY: clean
clean:
	docker-compose down -v || true

.PHONY: show-maps
show-maps:
	$(maps_cmd) | $(call docker_exec,"$$(cat -)")

.PHONY: show-tables
show-tables:
	$(tables_cmd) | $(call docker_exec,"$$(cat -)")

.PHONY: watch-maps
watch-maps:
	$(maps_cmd) | $(call while_exec,1,$$(cat -))

.PHONY: watch-tables
watch-tables:
	$(tables_cmd) | $(call while_exec,1,$$(cat -))


#-- Configuration ---------------------------------------------------------------------------------------------------------

run_file	:= doorstatus.be
add_files	:= params.json 

device_type 	:= berner
target_ip 		:= 172.29.2.197
password 		:= $(shell cat password.txt)

SHELL = bash

$(eval open_sensor_name := $(shell cat params.json | jq -r '.open_sensor_name'))
$(eval closed_sensor_name := $(shell cat params.json | jq -r '.closed_sensor_name'))
$(eval relay_power_num_up := $(shell cat params.json | jq -r '.relay_power_num_up'))
$(eval relay_power_num_down := $(shell cat params.json | jq -r '.relay_power_num_down'))


#-- Helper functions --------------------------------------------------------------------------------------------------------

define send_command # 1: command to send
	@sleep 0.1
	@curl -u admin:$(password) -G --data-urlencode 'cmnd=$(1)' http://$(target_ip)/cm
	@echo ""
endef

define wait_online # 1: pre-sleep time, 2: ping count, 3: post-sleep time
	@echo "Waiting for device to come online..."
	@sleep $(1)
	@ping -c $(2) -o $(target_ip)> /dev/null
	@sleep $(3)
endef

define get_id_from_device
	$(eval target_id := $(shell curl -u admin:$(password) -G --data-urlencode 'cmnd=Status 5' http://$(target_ip)/cm 2>/dev/null | jq -r '.StatusNET.Mac | split(":") | add | .[-6:]'))
endef


#-- Makefile targets -------------------------------------------------------------------------------------------------------

all: run


upload: $(run_file) $(add_files)
	@for dep in $^; do \
    	curl -u admin:$(password) -F "file=@$$dep" http://$(target_ip)/ufsu > /dev/null; \
	done


run: upload
	$(call send_command, brrestart)
	$(call send_command, br load("$(run_file)"))


restart:
	$(call send_command, restart 1)


configure:
	$(call wait_online, 0, 1, 0)
	$(call get_id_from_device)
	@echo 'target_id set to $(target_id)'

	@echo 'Erase all flash and reset parameters to firmware defaults but keep Wi-Fi settings and restart'
	$(call send_command, Reset 5)
	$(call wait_online, 5, 15, 2)

	@echo 'Configuring Tasmota template on target device...'
	@curl -u admin:$(password) -G --data-urlencode 'cmnd=Template {"NAME":"ESP32_Relay_X2","GPIO":[0,0,0,0,0,0,0,0,0,0,0,0,224,225,0,162,0,163,0,544,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"FLAG":0,"BASE":1}' http://$(target_ip)/cm
	$(call send_command, Module 0)
	$(call wait_online, 5, 15, 2)

	$(call send_command, FriendlyName $(device_type)-$(target_id))
	$(call send_command, DeviceName $(device_type)-$(target_id))
	$(call send_command, SetOption73 1)
	$(call send_command, Setoption114 1)
	$(call send_command, SwitchMode3 2)
	$(call send_command, SwitchMode4 2)
	$(call send_command, SwitchText3 $(open_sensor_name))
	$(call send_command, SwitchText4 $(closed_sensor_name))
	$(call send_command, SerialLog 0)
	$(call send_command, PulseTime1 5)
	$(call send_command, PulseTime2 5)
	$(call send_command, WebButton$(relay_power_num_up) Door up)
	$(call send_command, FriendlyName$(relay_power_num_up) Door up)
	$(call send_command, WebButton$(relay_power_num_down) Door down)
	$(call send_command, FriendlyName$(relay_power_num_down) Door down)
	$(call send_command, MqttClient $(device_type)-%06X)
	$(call send_command, Topic $(device_type)-%06X)
	$(call send_command, FullTopic /tasmota/%topic%/%prefix%/)
	$(call send_command, MqttHost mqtt.roelle.home)
	$(call send_command, WebPassword $(password))
	$(call send_command, restart 1)

	$(call wait_online, 5, 15, 0)
	@echo 'Done.'


upload-autoexec: autoexec.be
	$(call wait_online, 0, 15, 5)
	@curl -u admin:$(password) -F "file=@$^" http://$(target_ip)/ufsu > /dev/null; \


install: configure upload-autoexec upload restart


.PHONY: all run restart configure
# Garage door status driver for Tasmota
#
# (c) by Dr. harald Roelle in 2026
#
# This driver uses two Tasmota rules to monitor the state of a garage door based on two sensors: 
# one that indicates if the door is fully open and another that indicates if the door is fully closed.
# Based on the state of these sensors and the time since the last state change, the driver determines 
# if the door is fully open, fully closed, moving up, moving down, or somewhere in between (open).
#
# In addition this driver includes its own extra MQTT based Home Assistant integration

import string
import json
import introspect
import mqtt

var DOORSTATE_VERSION = "1.0.0"

class ConfigParams
    static var _param_file = "params.json"
    static var _door_command_up = "up"
    static var _door_command_down = "down"
    static var _is_initialized = _class._read_config()

    static var open_sensor_name
    static var closed_sensor_name
    static var doorstate_sensor_name
    static var position_sensor_name

    static var moving_time          # time in seconds that the door needs to move from fully open to fully closed or vice versa
    static var relay_power_num_up
    static var relay_power_num_down

    static var doordrive_manufacturer
    static var doordrive_model
    static var doordrive_serial_number

    static var ha_name
    static var ha_discovery_base

    static def _read_config()
        var f = open(_class._param_file, "r")
        var json_map = json.load(f.read())
        f.close()

        var success = true
        for key : introspect.members(_class)
            if string.startswith(key, "_") || type(introspect.get(_class, key)) == "function"
                continue
            end
            if ! json_map[key]
                log(f"ConfigParams: missing config parameter '{key}' in {_class._param_file}")
                success = false
            end
            introspect.set(_class, key, json_map[key])
        end

        return success
    end

    static def log_self()
        for key : introspect.members(_class)
            if string.startswith(key, "_") || type(introspect.get(_class, key)) == "function"
                continue
            end
            log(f"ConfigParams.{key} = {introspect.get(_class, key)}")
        end
    end
end


class SysParams
    static var tasmota_version = tasmota.cmd('_status 2')['StatusFWR']['Version']

    static var mac = tasmota.cmd('_status 5')['StatusNET']['Mac']
    static var device_id = string.tr(_class.mac, ":", "")[-6..-1]

    static var mqtt_topic_tele_BASE = 
            string.replace(
                string.replace(
                    string.replace( tasmota.cmd('_FullTopic',true)['FullTopic'], '%topic%', tasmota.cmd('_Topic',true)['Topic']),
                '%prefix%', tasmota.cmd('_Prefix',true)['Prefix3']),
            '%06X', _class.device_id)
    static var mqtt_topic_cmnd_BASE = 
            string.replace(
                string.replace(
                    string.replace( tasmota.cmd('_FullTopic',true)['FullTopic'], '%topic%', tasmota.cmd('_Topic',true)['Topic']),
                '%prefix%', tasmota.cmd('_Prefix',true)['Prefix1']),
            '%06X', _class.device_id)

    static var mqtt_topic_tele_lwt = _class.mqtt_topic_tele_BASE + 'LWT'
    static var mqtt_topic_tele_sensor = _class.mqtt_topic_tele_BASE + 'SENSOR'

    static def log_self()
        for key : introspect.members(_class)
            if string.startswith(key, "_") || type(introspect.get(_class, key)) == "function"
                continue
            end
            log(f"SysParams.{key} = {introspect.get(_class, key)}")
        end
    end
end


class DoorState
    static var UNKNOWN     = 0
    static var FULL_OPEN   = 1
    static var MOVING_DOWN = 2
    static var CLOSED      = 3
    static var MOVING_UP   = 4
    static var OPEN        = 5

    static def to_string(state)
        if   state == _class.UNKNOWN return "UNKNOWN"
        elif state == _class.FULL_OPEN return "open"
        elif state == _class.MOVING_DOWN return "closing"
        elif state == _class.CLOSED return "closed"
        elif state == _class.MOVING_UP return "opening"
        elif state == _class.OPEN return "partial_open"
        else return "INVALID" end
    end

    static def get_fake_position(state)
        if   state == _class.FULL_OPEN return 0
        elif state == _class.MOVING_DOWN return 30
        elif state == _class.CLOSED return 100
        elif state == _class.MOVING_UP return 70
        else return 50 end
    end
end


class GarageDoor
    var state
    var is_open
    var is_closed
    var _last_state_change_time

    var _mqtt_connected
    var _mqtt_topic_cmnd_door

    var _ha_id
    var _ha_disco_message
    var _ha_disco_topic


    # --------------------------------------------------------------------------------------------------
    # Driver methods

    def init()
        self.state = -1 # invalid state to force update on first run
        self._set_state(DoorState.UNKNOWN)
        self.is_open = false
        self.is_closed = false

        self._mqtt_connected = false
        self._mqtt_topic_cmnd_door = SysParams.mqtt_topic_cmnd_BASE + 'Door'

        ConfigParams.log_self()
        SysParams.log_self()
        self._ha_init()

        var statSNS = tasmota.cmd("_status 8")
        self._calculate_state(statSNS["StatusSNS"][ConfigParams.open_sensor_name] == "ON", statSNS["StatusSNS"][ConfigParams.closed_sensor_name] == "ON")

        tasmota.add_driver(self)
        tasmota.add_rule(f"{ConfigParams.open_sensor_name}#Action", / value, trigger, msg -> self._is_open_triggered(value, trigger, msg), "garage_door_is_open")
        tasmota.add_rule(f"{ConfigParams.closed_sensor_name}#Action", / value, trigger, msg -> self._is_closed_triggered(value, trigger, msg), "garage_door_is_closed")

        print("GarageDoor: initialized")
    end

    
    def every_second()
        if (tasmota.millis() - self._last_state_change_time) > (ConfigParams.moving_time * 1000)
            if (self.state == DoorState.MOVING_UP) || (self.state == DoorState.MOVING_DOWN)
                # if moving for too long, assume the door is somewhere in between fully open and closed
                self._set_state(DoorState.OPEN)
            end
        end
        var old_con_stat = self._mqtt_connected
        if (self._mqtt_connected := mqtt.connected()) != old_con_stat
            if self._mqtt_connected
                self._mqtt_on_connect()
            else
                self._mqtt_on_disconnect()
            end
        end
    end

    
    # Display door state value in the web UI
    def web_sensor()
        var msg = string.format("{s}Door state{m}%s{e}", DoorState.to_string(self.state))
        tasmota.web_send_decimal(msg)
    end
    
    # Add door state value to teleperiod
    def json_append()
        var msg = string.format(",\"%s\":\"%s\"", ConfigParams.doorstate_sensor_name, DoorState.to_string(self.state))
        tasmota.response_append(msg)
        msg = string.format(",\"%s\":\"%s\"", ConfigParams.position_sensor_name, DoorState.get_fake_position(self.state))
        tasmota.response_append(msg)
    end
    

    # --------------------------------------------------------------------------------------------------
    # Private methods

    def _is_open_triggered(value, trigger, msg)
        self._calculate_state(value=='OFF'?false:true, nil)
    end    

    def _is_closed_triggered(value, trigger, msg)
        self._calculate_state(nil, value=='OFF'?false:true)
    end    

    def _calculate_state(is_open, is_closed)
        var old_state = self.state
        if is_open==false && is_closed==false
            self._set_state(DoorState.OPEN)
        else
            if is_open != nil
                if self.is_open != is_open
                    if is_open
                        self._set_state(DoorState.FULL_OPEN)
                    else
                        self._set_state(DoorState.MOVING_DOWN)
                    end
                    self.is_open = is_open
                end
            end
            if is_closed != nil
                if self.is_closed != is_closed
                    if is_closed
                        self._set_state(DoorState.CLOSED)
                    else
                        self._set_state(DoorState.MOVING_UP)
                    end
                    self.is_closed = is_closed
                end
            end
        end
        if self.state != old_state
        end
    end

    def _set_state(new_state)
        if new_state != self.state
            self.state = new_state
            self._last_state_change_time = tasmota.millis()
            tasmota.cmd("_telePeriod") # trigger teleperiod update to send new state to MQTT
            log(f"GarageDoor: state changed to {DoorState.to_string(self.state)}")
        end
    end

    def _mqtt_on_connect()
        self._ha_publish_discovery()
        mqtt.subscribe(self._mqtt_topic_cmnd_door, / topic, idx, payload_s, payload_b -> self._mqtt_do_door_movement(topic, idx, payload_s, payload_b))
    end

    def _mqtt_on_disconnect()
    end

    def _mqtt_do_door_movement(topic, idx, payload_s, payload_b)
        if   string.startswith(payload_s, ConfigParams._door_command_up, true)
            tasmota.set_power(ConfigParams.relay_power_num_up-1, true)
        elif string.startswith(payload_s, ConfigParams._door_command_down, true)
            tasmota.set_power(ConfigParams.relay_power_num_down-1, true)
        end
    end


    # --------------------------------------------------------------------------------------------------
    # Custom home assistant discovery methods

    def _ha_init()
        self._ha_id = "garagedoor_" + string.tr(SysParams.mac, ":", "")

        self._ha_disco_topic = ConfigParams.ha_discovery_base + "/cover/" + self._ha_id + "/main/config"
        while string.find(self._ha_disco_topic, "//") != -1
            self._ha_disco_topic = string.replace(self._ha_disco_topic, "//", "/")
        end

        var ha_device_spec = {
            "sw_version" : f"{SysParams.tasmota_version}, DoorState {DOORSTATE_VERSION}",
            "hw_version" : f"{tasmota.cmd('_status 2')['StatusFWR']['Hardware']}",
            "configuration_url" : f"http://{tasmota.cmd('_status 5')['StatusNET']['IPAddress']}",
            "identifiers" : self._ha_id,
            "name" : ""
        }
        if ConfigParams.doordrive_manufacturer
            ha_device_spec["manufacturer"] = ConfigParams.doordrive_manufacturer
            ha_device_spec["name"] = ConfigParams.doordrive_manufacturer + " "
        end
        if ConfigParams.doordrive_model
            ha_device_spec["model"] = ConfigParams.doordrive_model
            ha_device_spec["name"] = ha_device_spec["name"] + ConfigParams.doordrive_model
        end
        if ConfigParams.doordrive_serial_number
            ha_device_spec["serial_number"] = ConfigParams.doordrive_serial_number
        end

        self._ha_disco_message = {
            "platform" : "cover",
            "device_class" : "garage",
            "name" : ConfigParams.ha_name != "" ? ConfigParams.ha_name : "Garage Door",
            "unique_id" : f"{self._ha_id}_cover",
            "default_entity_id" : f"cover.{self._ha_id}",
            "availability_topic" : SysParams.mqtt_topic_tele_lwt,
            "payload_available" : "Online",
            "payload_not_available" : "Offline",
            "state_closed" : DoorState.to_string(DoorState.CLOSED),
            "state_closing" : DoorState.to_string(DoorState.MOVING_DOWN),
            "state_open" : DoorState.to_string(DoorState.FULL_OPEN),
            "state_opening" : DoorState.to_string(DoorState.MOVING_UP),
            "state_stopped" : DoorState.to_string(DoorState.OPEN),
            "state_topic" : SysParams.mqtt_topic_tele_sensor,
            "value_template" : f"{{{{ value_json.{ConfigParams.doorstate_sensor_name} }}}}",
            "position_topic" : SysParams.mqtt_topic_tele_sensor,
            "position_template" : f"{{{{ value_json.{ConfigParams.position_sensor_name} }}}}",
            "command_topic" : self._mqtt_topic_cmnd_door,
            "payload_close" : ConfigParams._door_command_down,
            "payload_open" : ConfigParams._door_command_up,
            "payload_stop" : nil
        }
        self._ha_disco_message["device"] = ha_device_spec
    end

    def _ha_publish_discovery()
        mqtt.publish(self._ha_disco_topic, json.dump(self._ha_disco_message), true)        # retained
    end

end

GarageDoor()

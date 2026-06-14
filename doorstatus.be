# Garage door controller for Tasmota
#
# (c) by Dr. harald Roelle in 2026
#

import string
import json
import introspect
import mqtt
import math
import webserver
import persist

var GARAGEDOOR_VERSION = "1.0.0"

class ConfigParams
    static var _param_file = "params.json"
    static var _door_command_up = "up"
    static var _door_command_down = "down"
    static var _doorstate_sensor_name = "DOOR_STATE"
    static var _position_sensor_name = "POSITION"
    static var _openingtime_sensor_name = "OPENING_TIME"
    static var _closingtime_sensor_name = "CLOSING_TIME"
    static var _min_moving_time = 4*1000        # min time in msec that a door needs to move from fully open to fully closed or vice versa
    static var _max_moving_time = 60*1000       # max time in msec that a door needs to move from fully open to fully closed or vice versa
    static var _is_initialized = _class._read_config()

    static var open_sensor_name
    static var closed_sensor_name

    static var relay_power_num_up
    static var relay_power_num_down

    static var doordrive_manufacturer
    static var doordrive_model
    static var doordrive_serial_number

    static var homeassistant_enabled
    static var ha_name
    static var ha_discovery_base

    static var persisting_cycle_minutes

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

    var state
    var opening_time
    var closing_time

    var _last_state_change_time
    var _last_state_duration
    var _state_changed_callback

    def init(state_changed_callback)
        self._state_changed_callback = state_changed_callback
        self.state = -1 # invalid state to force update on first run
        self.opening_time = int(persist.find(f"{_class}.opening_time", 0))
        self.closing_time = int(persist.find(f"{_class}.closing_time", 0))
        self._last_state_change_time = tasmota.millis()
        self._set_state_internal(_class.UNKNOWN)
    end

    def get_state_duration()
        return tasmota.millis() - self._last_state_change_time
    end

    def set_full_open()
        return self._set_state_internal(_class.FULL_OPEN)
    end
    def set_moving_down()
        return self._set_state_internal(_class.MOVING_DOWN)
    end
    def set_closed()
        return self._set_state_internal(_class.CLOSED)
    end
    def set_moving_up()
        return self._set_state_internal(_class.MOVING_UP)
    end
    def set_open()
        return self._set_state_internal(_class.OPEN)
    end

    def to_string()
        return _class.state_string(self.state)
    end

    def get_calc_position()
        if   self.state == _class.FULL_OPEN return 100
        elif self.state == _class.CLOSED return 0
        elif self.state == _class.MOVING_DOWN
            if self.closing_time==0
                return 75
            end
            return tasmota.int(100-(100*self.get_state_duration()) / self.closing_time, 0, 100)
        elif self.state == _class.MOVING_UP
            if self.opening_time==0
                return 25
            end
            return tasmota.int((100*self.get_state_duration()) / self.opening_time, 0, 100)
        else return 50 end
    end

    def reset_calibration()
        self.opening_time = 0
        self.closing_time = 0
        self.update_persistant_data(true)
    end

    def update_persistant_data(force_write)
        persist.setmember(f"{_class}.opening_time", self.opening_time)
        persist.setmember(f"{_class}.closing_time", self.closing_time)
        if force_write
            persist.save(true)
        end
    end

    def _set_state_internal(new_state)
        if new_state != self.state
            var now = tasmota.millis()
            self._last_state_duration = now - self._last_state_change_time

            # Auto calibration: Time should be in certain bounds anyway
            if self._last_state_duration>ConfigParams._min_moving_time && self._last_state_duration<ConfigParams._max_moving_time
                # Auto calibration: opening
                if self.state == _class.MOVING_UP && new_state == _class.FULL_OPEN
                    # Accept time only if uncalibrated or +/- 15% of the previous value
                    if self.opening_time==0 || (self._last_state_duration>self.opening_time*0.85 && self._last_state_duration<self.opening_time*1.15) 
                        self.opening_time = self._last_state_duration
                        self.update_persistant_data()
                    end
                # Auto calibration: closing
                elif self.state == _class.MOVING_DOWN && new_state == _class.CLOSED
                    # Accept time only if uncalibrated or +/- 15% of the previous value
                    if self.closing_time==0 || (self._last_state_duration>self.closing_time*0.85 && self._last_state_duration<self.closing_time*1.15) 
                        self.closing_time = self._last_state_duration
                        self.update_persistant_data()
                    end
                end
            end

            self._last_state_change_time = now
            self.state = new_state
            self._state_changed_callback(self)
            return true
        else
            return false
        end
    end

    static def state_string(state)
        if   state == _class.UNKNOWN return "UNKNOWN"
        elif state == _class.FULL_OPEN return "open"
        elif state == _class.MOVING_DOWN return "closing"
        elif state == _class.CLOSED return "closed"
        elif state == _class.MOVING_UP return "opening"
        elif state == _class.OPEN return "partial_open"
        else return "INVALID" end
    end

end


class GarageDoor
    var doorstate
    var is_open
    var is_closed

    var _persist_period
    var _last_persist_save

    var _mqtt_connected
    var _mqtt_topic_cmnd_door

    var _ha_id
    var _ha_disco_message_json
    var _ha_disco_topic


    # --------------------------------------------------------------------------------------------------
    # Driver methods

    def init()
        self.doorstate = DoorState(/ instance -> self._doorstate_changed_callback(instance))
        self.is_open = false
        self.is_closed = false

        self._persist_period = ConfigParams.persisting_cycle_minutes *60*1000
        self._last_persist_save = tasmota.millis()

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
        var now = tasmota.millis()

        # write persistant data from time to time
        if self._persist_period!=0 && ((now-self._last_persist_save)>self._persist_period)
            persist.save()
            self._last_persist_save = now
            log(f"{_class}: Persisting data")
        end

        # if moving for too long, assume the door is stopped somewhere in between fully open and closed
        var limit
        if self.doorstate.opening_time==0 || self.doorstate.closing_time==0
            limit = ConfigParams._max_moving_time
        else
            limit = math.max(self.doorstate.opening_time*1.15, self.doorstate.closing_time*1.15)
        end
        if    self.doorstate.get_state_duration()>limit 
           && ( (self.doorstate.state == DoorState.MOVING_UP) || (self.doorstate.state == DoorState.MOVING_DOWN) )
            self.doorstate.set_open()
        end

        # check mqtt status
        var old_con_stat = self._mqtt_connected
        if (self._mqtt_connected := mqtt.connected()) != old_con_stat
            if self._mqtt_connected
                self._mqtt_on_connect()
            else
                self._mqtt_on_disconnect()
            end
        end

        if (self.doorstate.state == DoorState.MOVING_UP) || (self.doorstate.state == DoorState.MOVING_DOWN)
            tasmota.cmd("_telePeriod") # trigger teleperiod update to send new state to MQTT
        end
    end

    def web_add_main_button()
        webserver.content_send("<p></p><button onclick='la(\"&m_reset_calibration=1\");'>Reset Calibration</button>")
        webserver.content_send("<p></p><button onclick='la(\"&m_persist_data=1\");'>Persist Data</button>")
    end

    # Display doorstate value in the web UI
    def web_sensor()
        if webserver.has_arg("m_reset_calibration")
            self.doorstate.reset_calibration()
        elif webserver.has_arg("m_persist_data")
            persist.save(true)
        end
        tasmota.web_send( string.format("{s}Door state{m}%s{e}", self.doorstate.to_string()))
        tasmota.web_send( string.format("{s}Last state duration{m}%.1f{e}", self.doorstate._last_state_duration/1000.0))
        tasmota.web_send( string.format("{s}Opening time{m}%.1f{e}", self.doorstate.opening_time/1000.0))
        tasmota.web_send( string.format("{s}Closing time{m}%.1f{e}", self.doorstate.closing_time/1000.0))
        tasmota.web_send_decimal( string.format("{s}Door position{m}%d%%{e}", self.doorstate.get_calc_position()))
    end
    
    # Add doorstate value to teleperiod
    def json_append()
        tasmota.response_append(string.format(",\"%s\":\"%s\"", ConfigParams._doorstate_sensor_name, self.doorstate.to_string()))
        tasmota.response_append(string.format(",\"%s\":\"%d\"", ConfigParams._position_sensor_name, self.doorstate.get_calc_position()))
        tasmota.response_append(string.format(",\"%s\":\"%.1f\"", ConfigParams._openingtime_sensor_name, self.doorstate.opening_time/1000.0))
        tasmota.response_append(string.format(",\"%s\":\"%.1f\"", ConfigParams._closingtime_sensor_name, self.doorstate.closing_time/1000.0))
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
        if is_open==false && is_closed==false
            self.doorstate.set_open()
        else
            if is_open != nil
                if self.is_open != is_open
                    if is_open
                        self.doorstate.set_full_open()
                    else
                        self.doorstate.set_moving_down()
                    end
                    self.is_open = is_open
                end
            end
            if is_closed != nil
                if self.is_closed != is_closed
                    if is_closed
                        self.doorstate.set_closed()
                    else
                        self.doorstate.set_moving_up()
                    end
                    self.is_closed = is_closed
                end
            end
        end
    end

    def _doorstate_changed_callback(doorstate)
        tasmota.cmd("_telePeriod") # trigger teleperiod update to send new state to MQTT
        log(f"GarageDoor: state changed to {doorstate.to_string()}")
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
        if ! ConfigParams.homeassistant_enabled
            return
        end

        self._ha_id = "garagedoor_" + string.tr(SysParams.mac, ":", "")

        self._ha_disco_topic = ConfigParams.ha_discovery_base + "/device/" + self._ha_id + "/config"
        while string.find(self._ha_disco_topic, "//") != -1
            self._ha_disco_topic = string.replace(self._ha_disco_topic, "//", "/")
        end

        var ha_device_spec = {
            "sw_version" : f"{SysParams.tasmota_version}, GarageDoor {GARAGEDOOR_VERSION}",
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

        var ha_disco_message = {
            "origin": {
                "name" : "GarageDoor driver for Tasmota",
                "sw_version" : f"{SysParams.tasmota_version}, GarageDoor {GARAGEDOOR_VERSION}",
                "support_url" : "https://github.com/HaraldR42/garagedoor-tasmota"
            },
            "components": {
                f"{self._ha_id}_cover" : {
                    "platform" : "cover",
                    "device_class" : "garage",
                    "name" : ConfigParams.ha_name != "" ? ConfigParams.ha_name : "Garage Door",
                    "unique_id" : f"{self._ha_id}_cover",
                    "default_entity_id" : f"cover.{self._ha_id}",
                    "state_closed" : DoorState.state_string(DoorState.CLOSED),
                    "state_closing" : DoorState.state_string(DoorState.MOVING_DOWN),
                    "state_open" : DoorState.state_string(DoorState.FULL_OPEN),
                    "state_opening" : DoorState.state_string(DoorState.MOVING_UP),
                    "state_stopped" : DoorState.state_string(DoorState.OPEN),
                    "state_topic" : SysParams.mqtt_topic_tele_sensor,
                    "value_template" : f"{{{{ value_json.{ConfigParams._doorstate_sensor_name} }}}}",
                    "position_topic" : SysParams.mqtt_topic_tele_sensor,
                    "position_template" : f"{{{{ value_json.{ConfigParams._position_sensor_name} }}}}",
                    "command_topic" : self._mqtt_topic_cmnd_door,
                    "payload_close" : ConfigParams._door_command_down,
                    "payload_open" : ConfigParams._door_command_up,
                    "payload_stop" : nil
                },
                f"{self._ha_id}_openingtime" : {
                    "platform" : "sensor",
                    "device_class" : "duration",
                    "unique_id" : f"{self._ha_id}_openingtime",
                    "default_entity_id" : f"sensor.{self._ha_id}.duration.opening",
                    "name" : "Opening time",
                    "suggested_display_precision" : 1,
                    "state_topic" : SysParams.mqtt_topic_tele_sensor,
                    "value_template" : f"{{{{ value_json.{ConfigParams._openingtime_sensor_name} }}}}",
                    "unit_of_measurement" : "s"
                },
                f"{self._ha_id}_closingtime" : {
                    "platform" : "sensor",
                    "device_class" : "duration",
                    "unique_id" : f"{self._ha_id}_closingtime",
                    "default_entity_id" : f"sensor.{self._ha_id}.duration.closing",
                    "name" : "Closing time",
                    "suggested_display_precision" : 1,
                    "state_topic" : SysParams.mqtt_topic_tele_sensor,
                    "value_template" : f"{{{{ value_json.{ConfigParams._closingtime_sensor_name} }}}}",
                    "unit_of_measurement" : "s"
                },
            },
            "availability_topic" : SysParams.mqtt_topic_tele_lwt,
            "payload_available" : "Online",
            "payload_not_available" : "Offline",
        }
        ha_disco_message["device"] = ha_device_spec

        self._ha_disco_message_json = json.dump(ha_disco_message)
    end


    def _ha_publish_discovery()
        if ! ConfigParams.homeassistant_enabled
            return
        end
        mqtt.publish(self._ha_disco_topic, self._ha_disco_message_json, true)        # retained
    end

end

GarageDoor()
